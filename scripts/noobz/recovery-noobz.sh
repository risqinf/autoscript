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

pass=$(db_query "SELECT secret FROM accounts WHERE protocol='noobz' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended') ORDER BY updated_at DESC LIMIT 1;")
exp_epoch=$(db_query "SELECT expired_at FROM accounts WHERE protocol='noobz' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended') ORDER BY updated_at DESC LIMIT 1;")
exp_system=$(date -d "@${exp_epoch}" +%Y-%m-%d 2>/dev/null || date -d "+30 days" +%Y-%m-%d)

noobzvpns user add "$user" "$pass" >/dev/null 2>&1 || true
noobzvpns user expire "$user" "$exp_system" >/dev/null 2>&1 || true

db_exec "UPDATE accounts SET status='active', updated_at=strftime('%s','now')
         WHERE protocol='noobz' AND username='$(sql_escape "$user")';"
db_audit "recover" "noobz" "$user" ""
ok "Recovered NoobzVPN account '$user'."

line
read -n 1 -s -r -p "Press any key to menu..."
menu
