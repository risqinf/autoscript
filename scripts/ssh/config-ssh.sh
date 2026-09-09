#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: View SSH account details
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init

clear
ui_header "SSH ACCOUNT DETAILS"
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime')
          FROM accounts WHERE protocol='ssh' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e; do printf " %-20s %s\n" "$u" "$e"; done
ui_rule

read -rp "Enter username: " user
if ! valid_username "$user" || ! db_account_exists "ssh" "$user"; then
  err "User not found."; read -n1 -s -r -p "Press any key..."; menu; exit 1
fi

pass=$(db_get_field "ssh" "$user" "secret")
ipl=$(db_get_field "ssh" "$user" "limit_ip"); [[ "$ipl" == "0" ]] && ipl="Unlimited"
qb=$(db_get_field "ssh" "$user" "quota_bytes")
[[ "$qb" == "0" || -z "$qb" ]] && quota_disp="Unlimited" || quota_disp="$(( qb / 1073741824 )) GB"
exp=$(db_query "SELECT datetime(expired_at,'unixepoch','localtime') FROM accounts WHERE protocol='ssh' AND username='$(sql_escape "$user")' AND status!='deleted';")

clear
ssh_print_cli "$user" "$pass" "$ipl" "$exp" "$quota_disp" "SSH ACCOUNT DETAILS"
read -n 1 -s -r -p " Press any key to back to menu..."
menu
