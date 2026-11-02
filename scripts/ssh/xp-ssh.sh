#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Auto-expire SSH accounts (DB-driven, zero-drop for active peers)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init
now=$(date +%s)

while IFS='|' read -r user; do
  [[ -z "$user" ]] && continue
  acc_ssh_kill_user "$user"
  id "$user" &>/dev/null && userdel --force "$user" >/dev/null 2>&1
  db_set_status "ssh" "$user" "expired"
  db_audit "expire" "ssh" "$user" ""
  tg_send "<b>[ SSH EXPIRED ]</b>%0AUsername: <code>${user}</code>"
done < <(db_query "SELECT username FROM accounts
                   WHERE protocol='ssh' AND status='active' AND expired_at < ${now};")

exit 0
