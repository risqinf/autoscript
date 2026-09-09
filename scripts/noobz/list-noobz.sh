#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: List NoobzVPN accounts
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init
clear
ui_header "NOOBZVPN ACCOUNT LIST"
printf " %-18s %-20s %-8s %-10s %-10s\n" "USERNAME" "EXPIRED" "DEVICE" "QUOTA" "STATUS"
ui_rule
total=0
while IFS='|' read -r u e dev qb s; do
  [[ -z "$u" ]] && continue
  q="Unl"
  if [[ -n "$qb" && "$qb" -gt 0 ]]; then
    q="$(( qb / 1073741824 ))G"
  fi
  [[ "$dev" == "0" ]] && dev="Unl"
  printf " %-18s %-20s %-8s %-10s %-10s\n" "$u" "$e" "$dev" "$q" "$s"
  total=$((total+1))
done < <(db_query "SELECT username, datetime(expired_at,'unixepoch','localtime'), limit_ip, quota_bytes, status
                   FROM accounts WHERE protocol='noobz' AND status!='deleted'
                   ORDER BY username;")
ui_rule
echo -e " Total: ${GREEN}${total}${NC} account(s)"
ui_back
menu
