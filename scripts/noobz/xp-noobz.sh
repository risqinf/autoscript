#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Auto-expire NOOBZVPN accounts (DB-driven)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init
now=$(date +%s)
count=0

while IFS='|' read -r user; do
  [[ -z "$user" ]] && continue
  if command -v noobzvpns &>/dev/null; then
    noobzvpns remove "$user" >/dev/null 2>&1 || true
  fi
  db_set_status "noobz" "$user" "expired"
  db_audit "expire" "noobz" "$user" ""
  tg_send "<b>[ NOOBZVPN EXPIRED ]</b>%0AUsername: <code>${user}</code>"
  count=$((count+1))
done < <(db_query "SELECT username FROM accounts
                   WHERE protocol='noobz' AND status='active' AND expired_at < ${now};")

exit 0
