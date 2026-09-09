#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Delete NoobzVPN account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init

clear
ui_header "DELETE NOOBZVPN ACCOUNT"
printf " %-20s %-22s %-10s\n" "USERNAME" "EXPIRED" "STATUS"
ui_rule
db_query "SELECT username, datetime(expired_at,'unixepoch','localtime'), status
          FROM accounts WHERE protocol='noobz' AND status!='deleted'
          ORDER BY username;" \
  | while IFS='|' read -r u e s; do printf " %-20s %-22s %-10s\n" "$u" "$e" "$s"; done
ui_rule

read -rp " Username to delete: " user
if ! valid_username "$user"; then err "Invalid username."; ui_back; menu; exit 1; fi
if ! db_account_exists "noobz" "$user"; then err "User not found."; ui_back; menu; exit 1; fi

read -rp " Delete '$user'? (y/N): " c
[[ "$c" =~ ^[Yy]$ ]] || { warn "Cancelled."; ui_back; menu; exit 0; }

if acc_noobz_delete "$user"; then
  tg_send "<b>[ NOOBZVPN DELETED ]</b>%0AUsername: <code>$(html_escape "$user")</code>"
  ok "User '$user' deleted successfully."
else
  err "Failed to delete '$user'."
fi
ui_back
menu
