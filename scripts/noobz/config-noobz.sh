#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: View NoobzVPN account details
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init

clear
ui_header "NOOBZVPN ACCOUNT DETAILS"
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime')
          FROM accounts WHERE protocol='noobz' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e; do printf " %-20s %s\n" "$u" "$e"; done
ui_rule

read -rp " Enter username: " user
if ! valid_username "$user" || ! db_account_exists "noobz" "$user"; then
  err "User not found."; ui_back; menu; exit 1
fi

pass=$(db_get_field "noobz" "$user" "secret")
dev=$(db_get_field "noobz" "$user" "limit_ip"); [[ "$dev" == "0" ]] && dev="Unlimited"
qb=$(db_get_field "noobz" "$user" "quota_bytes")
[[ "$qb" == "0" || -z "$qb" ]] && quota_disp="Unlimited" || quota_disp="$(( qb / 1073741824 )) GB"
exp=$(db_query "SELECT datetime(expired_at,'unixepoch','localtime') FROM accounts WHERE protocol='noobz' AND username='$(sql_escape "$user")' AND status!='deleted';")

clear
noobz_print_cli "$user" "$pass" "$dev" "$exp" "$quota_disp" "NOOBZVPN ACCOUNT DETAILS"
ui_back
menu
