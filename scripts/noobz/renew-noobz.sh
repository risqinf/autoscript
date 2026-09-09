#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Renew NoobzVPN account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init

clear
ui_header "RENEW NOOBZVPN ACCOUNT"
printf " %-20s %-22s\n" "USERNAME" "EXPIRED"
ui_rule
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime')
          FROM accounts WHERE protocol='noobz' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e; do printf " %-20s %-22s\n" "$u" "$e"; done
ui_rule

read -rp " Username to renew: " user
read -rp " Add days         : " days
if ! valid_username "$user"; then err "Invalid username."; ui_back; menu; exit 1; fi
if ! valid_days "$days"; then err "Days must be 1-3650."; ui_back; menu; exit 1; fi
if ! db_account_exists "noobz" "$user"; then err "User not found."; ui_back; menu; exit 1; fi

new_epoch=$(acc_noobz_renew "$user" "$days")
if [[ -n "$new_epoch" ]]; then
  new_disp=$(date -d "@${new_epoch}" +"%d-%m-%Y %H:%M:%S")
  tg_send "<b>[ NOOBZVPN RENEWED ]</b>%0AUsername: <code>$(html_escape "$user")</code>%0ANew expiry: <code>${new_disp}</code>"
  ok "Renewed '$user' by ${days} days. New expiry: ${new_disp}"
else
  err "Renew failed."
fi
ui_back
menu
