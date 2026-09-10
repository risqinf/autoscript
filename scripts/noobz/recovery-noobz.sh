#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Recover (restore) deleted/suspended NoobzVPN account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init

clear
line
echo -e "${WHITE}  RECOVERY NOOBZVPN ACCOUNT${NC}"
line
printf "%-20s %-22s %-10s\n" "USERNAME" "EXPIRED" "STATUS"
echo "------------------------------------------------------------"
total=0
while IFS='|' read -r u e s; do
  [[ -z "$u" ]] && continue
  printf "%-20s %-22s %-10s\n" "$u" "$e" "$s"
  total=$((total+1))
done < <(db_query "SELECT username, datetime(expired_at,'unixepoch','localtime'), status
                   FROM accounts WHERE protocol='noobz' AND status IN ('deleted','suspended')
                   ORDER BY updated_at DESC;")
line
if [[ $total -eq 0 ]]; then
  warn "No recoverable NoobzVPN accounts."
  read -n 1 -s -r -p "Press any key to menu..."; menu; exit 0
fi

read -rp "Enter username to recover: " user
if ! valid_username "$user"; then err "Invalid username."; read -n1 -s -r -p "Press any key..."; menu; exit 1; fi

cnt=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='noobz' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended');")
[[ "$cnt" -gt 0 ]] || { err "Not a recoverable account."; read -n1 -s -r -p "Press any key..."; menu; exit 1; }

read -rp "Enter days until expiration (default 30): " days
days="${days:-30}"
if ! valid_days "$days"; then err "Days must be 1-3650."; read -n1 -s -r -p "Press any key..."; menu; exit 1; fi

if acc_noobz_recover "$user" "$days"; then
  new_epoch=$(db_get_field "noobz" "$user" "expired_at")
  new_disp=$(date -d "@${new_epoch}" +"%d-%m-%Y %H:%M:%S")
  tg_send "<b>[ NOOBZVPN RECOVERED ]</b>%0AUsername: <code>$(html_escape "$user")</code>%0AExpiry: <code>${new_disp}</code>"
  ok "Recovered NoobzVPN account '$user' (expires: ${new_disp})."
else
  err "Failed to recover '$user'."
fi

line
read -n 1 -s -r -p "Press any key to menu..."
menu
