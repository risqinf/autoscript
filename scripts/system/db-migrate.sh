#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: One-time migration: .txt + config markers -> SQLite + pure JSON
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/common.sh
. /usr/local/sbin/lib/db.sh
. /usr/local/sbin/lib/xraycfg.sh

require_root
db_init

clear
line
echo -e "${WHITE}            DATABASE MIGRATION (txt -> sqlite)${NC}"
line

migrated=0

# Convert a display/legacy expired value to epoch.
to_epoch() {
  local raw="$1" datepart
  # Accept "DD-MM-YYYY HH:MM:SS" or "YYYY-MM-DD-HH-MM-SS" or "YYYY-MM-DD"
  if [[ "$raw" =~ ^[0-9]{2}-[0-9]{2}-[0-9]{4} ]]; then
    datepart=$(echo "$raw" | awk '{print $1}')
    local d m y; IFS='-' read -r d m y <<< "$datepart"
    date -d "${y}-${m}-${d}" +%s 2>/dev/null
  elif [[ "$raw" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]]; then
    date -d "$(echo "$raw" | cut -d'-' -f1-3)" +%s 2>/dev/null
  else
    echo ""
  fi
}

migrate_proto() {
  local proto="$1" dbdir="/etc/xray/database/${proto}"
  [[ -d "$dbdir" ]] || return 0
  local f user secret quota ip exp epoch qbytes
  for f in "$dbdir"/*.txt; do
    [[ -f "$f" ]] || continue
    user=$(basename "$f" .txt)
    valid_username "$user" || { warn "skip invalid username: $user"; continue; }
    db_account_exists "$proto" "$user" && continue

    secret=$(grep -iE '^(uuid|password):' "$f" | head -1 | awk '{print $2}')
    ip=$(grep -i '^limit_ip:' "$f" | awk '{print $2}'); ip=${ip:-0}
    quota=$(grep -i '^quota:' "$f" | awk '{print $2}'); quota=${quota:-0}
    exp=$(grep -i '^expired:' "$f" | cut -d' ' -f2-)
    epoch=$(to_epoch "$exp"); epoch=${epoch:-$(( $(date +%s) + 86400 ))}
    qbytes=0; [[ "$quota" =~ ^[0-9]+$ ]] && (( quota > 0 )) && qbytes=$(( quota * 1073741824 ))
    [[ -z "$secret" ]] && { warn "skip $proto/$user (no secret)"; continue; }

    db_insert_account "$proto" "$user" "$secret" "$qbytes" "$ip" "$epoch" \
      && { ok "migrated ${proto}/${user}"; migrated=$((migrated+1)); db_audit "migrate" "$proto" "$user" "from txt"; }
  done
}

# SSH: usernames come from db/ssh/*.txt
migrate_proto ssh
migrate_proto vless
migrate_proto vmess
migrate_proto trojan
migrate_proto noobz

# Strip comment markers from config.json so it becomes pure JSON.
if [[ -f "$AS_CONFIG" ]] && grep -qE '#÷|###|#@' "$AS_CONFIG"; then
  info "Stripping legacy comment markers from config.json..."
  cp -f "$AS_CONFIG" "${AS_CONFIG}.premigrate"
  sed -i -E '/^#(÷|@)/d; /^###[^"]/d' "$AS_CONFIG"
  # Validate; if broken, restore.
  if jq -e . "$AS_CONFIG" >/dev/null 2>&1; then
    ok "config.json markers removed (backup: ${AS_CONFIG}.premigrate)"
  else
    mv -f "${AS_CONFIG}.premigrate" "$AS_CONFIG"
    warn "Could not safely strip markers automatically; left config.json unchanged."
  fi
fi

line
ok "Migration complete. Accounts migrated: ${migrated}"
warn "Verify accounts, then archive /etc/xray/database/*.txt once satisfied."
line
