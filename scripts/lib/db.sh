#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SQLite3 database access layer (enterprise)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -n "${__AS_DB_LOADED:-}" ]] && return 0
__AS_DB_LOADED=1

[[ -n "${__AS_COMMON_LOADED:-}" ]] || . "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Busy timeout avoids "database is locked" under the looping services.
AS_SQLITE_TIMEOUT=8000

# Run a SQL statement. Reads SQL from $1 (or stdin if $1 omitted).
db_exec() {
  local sql="$1"
  if [[ -n "$sql" ]]; then
    sqlite3 -cmd ".timeout ${AS_SQLITE_TIMEOUT}" "$AS_DB" "$sql"
  else
    sqlite3 -cmd ".timeout ${AS_SQLITE_TIMEOUT}" "$AS_DB"
  fi
}

# Query returning rows; caller sets separator via $2 (default '|').
db_query() {
  local sql="$1" sep="${2:-|}"
  sqlite3 -cmd ".timeout ${AS_SQLITE_TIMEOUT}" -separator "$sep" "$AS_DB" "$sql"
}

# Escape a value for safe single-quoted SQL embedding (defense in depth;
# inputs are already validated by the lib validators).
sql_escape() { printf "%s" "$1" | sed "s/'/''/g"; }

# Initialize schema (idempotent). Sets secure file perms.
db_init() {
  mkdir -p "$AS_ETC"
  chmod 700 "$AS_ETC" 2>/dev/null
  db_exec "
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;

CREATE TABLE IF NOT EXISTS meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS accounts (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol     TEXT NOT NULL CHECK (protocol IN ('ssh','vless','vmess','trojan','noobz')),
  username     TEXT NOT NULL,
  secret       TEXT NOT NULL,                 -- password (ssh) or uuid/password (xray)
  quota_bytes  INTEGER NOT NULL DEFAULT 0,    -- 0 = unlimited
  used_bytes   INTEGER NOT NULL DEFAULT 0,
  limit_ip     INTEGER NOT NULL DEFAULT 0,    -- 0 = unlimited
  expired_at   INTEGER NOT NULL,              -- unix epoch
  status       TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','expired','deleted')),
  created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  updated_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  note         TEXT NOT NULL DEFAULT '',
  UNIQUE (protocol, username)
);

CREATE INDEX IF NOT EXISTS idx_accounts_proto_status ON accounts(protocol,status);
CREATE INDEX IF NOT EXISTS idx_accounts_expired ON accounts(expired_at);

CREATE TABLE IF NOT EXISTS audit_log (
  id        INTEGER PRIMARY KEY AUTOINCREMENT,
  ts        INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  actor     TEXT NOT NULL DEFAULT 'system',
  action    TEXT NOT NULL,
  protocol  TEXT,
  username  TEXT,
  detail    TEXT NOT NULL DEFAULT ''
);

INSERT OR IGNORE INTO meta(key,value) VALUES ('schema_version','1');
" >/dev/null 2>&1

  # Auto-migrate: ensure 'noobz' is permitted in protocol CHECK constraint for existing databases
  local cur_schema
  cur_schema=$(sqlite3 "$AS_DB" ".schema accounts" 2>/dev/null)
  if [[ -n "$cur_schema" ]] && ! echo "$cur_schema" | grep -q "'noobz'"; then
    db_exec "
PRAGMA foreign_keys=OFF;
BEGIN TRANSACTION;
CREATE TABLE accounts_migrate (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  protocol     TEXT NOT NULL CHECK (protocol IN ('ssh','vless','vmess','trojan','noobz')),
  username     TEXT NOT NULL,
  secret       TEXT NOT NULL,
  quota_bytes  INTEGER NOT NULL DEFAULT 0,
  used_bytes   INTEGER NOT NULL DEFAULT 0,
  limit_ip     INTEGER NOT NULL DEFAULT 0,
  expired_at   INTEGER NOT NULL,
  status       TEXT NOT NULL DEFAULT 'active'
                 CHECK (status IN ('active','suspended','expired','deleted')),
  created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  updated_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
  note         TEXT NOT NULL DEFAULT '',
  UNIQUE (protocol, username)
);
INSERT INTO accounts_migrate SELECT * FROM accounts;
DROP TABLE accounts;
ALTER TABLE accounts_migrate RENAME TO accounts;
CREATE INDEX IF NOT EXISTS idx_accounts_proto_status ON accounts(protocol,status);
CREATE INDEX IF NOT EXISTS idx_accounts_expired ON accounts(expired_at);
COMMIT;
PRAGMA foreign_keys=ON;
" >/dev/null 2>&1
  fi

  chmod 600 "$AS_DB" 2>/dev/null
  [[ -f "${AS_DB}-wal" ]] && chmod 600 "${AS_DB}-wal" 2>/dev/null
  [[ -f "${AS_DB}-shm" ]] && chmod 600 "${AS_DB}-shm" 2>/dev/null
}

db_audit() {
  local action="$1" proto="$2" user="$3" detail="$4" actor="${5:-$(whoami)}"
  db_exec "INSERT INTO audit_log(actor,action,protocol,username,detail)
           VALUES ('$(sql_escape "$actor")','$(sql_escape "$action")',
                   '$(sql_escape "$proto")','$(sql_escape "$user")',
                   '$(sql_escape "$detail")');"
}

# --- Account helpers ---
# Returns 0 if an active account exists.
db_account_exists() {
  local proto="$1" user="$2"
  local c
  c=$(db_query "SELECT COUNT(*) FROM accounts
                WHERE protocol='$(sql_escape "$proto")'
                  AND username='$(sql_escape "$user")'
                  AND status!='deleted';")
  [[ "$c" -gt 0 ]]
}

# Returns 0 if the secret (uuid/password) is used by any non-deleted account.
db_secret_in_use() {
  local secret="$1"
  local c
  c=$(db_query "SELECT COUNT(*) FROM accounts
                WHERE secret='$(sql_escape "$secret")' AND status!='deleted';")
  [[ "$c" -gt 0 ]]
}

# Insert account. Args: proto user secret quota_bytes limit_ip expired_at
db_insert_account() {
  db_exec "INSERT INTO accounts(protocol,username,secret,quota_bytes,limit_ip,expired_at,status)
           VALUES ('$(sql_escape "$1")','$(sql_escape "$2")','$(sql_escape "$3")',
                   $4, $5, $6, 'active');"
}

# Get a single field for an active account.
db_get_field() {
  local proto="$1" user="$2" field="$3"
  db_query "SELECT ${field} FROM accounts
            WHERE protocol='$(sql_escape "$proto")'
              AND username='$(sql_escape "$user")'
              AND status!='deleted' LIMIT 1;"
}

# Set status (active/suspended/expired/deleted).
db_set_status() {
  local proto="$1" user="$2" status="$3"
  db_exec "UPDATE accounts SET status='$(sql_escape "$status")',
             updated_at=strftime('%s','now')
           WHERE protocol='$(sql_escape "$proto")'
             AND username='$(sql_escape "$user")';"
}

db_set_expired() {
  local proto="$1" user="$2" epoch="$3"
  db_exec "UPDATE accounts SET expired_at=${epoch}, status='active',
             updated_at=strftime('%s','now')
           WHERE protocol='$(sql_escape "$proto")'
             AND username='$(sql_escape "$user")';"
}
