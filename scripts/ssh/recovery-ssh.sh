#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Recover (restore) deleted/expired SSH account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init

clear
line
echo -e "${WHITE}  RECOVERY SSH ACCOUNT${NC}"
line
printf "%-20s %-22s %-10s\n" "USERNAME" "EXPIRED" "STATUS"
echo "------------------------------------------------------------"
total=0
while IFS='|' read -r u e s; do
  [[ -z "$u" ]] && continue
  printf "%-20s %-22s %-10s\n" "$u" "$e" "$s"
  total=$((total+1))
done < <(db_query "SELECT username, datetime(expired_at,'unixepoch','localtime'), status
                   FROM accounts WHERE protocol='ssh' AND status IN ('deleted','suspended','expired')
                   ORDER BY updated_at DESC;")
line
if [[ $total -eq 0 ]]; then
  warn "No recoverable SSH accounts."
  read -n 1 -s -r -p "Press any key to menu..."; menu; exit 0
fi

read -rp "Username to recover: " user
read -rp "New expiry (days from now): " days
if ! valid_username "$user"; then err "Invalid username."; read -n1 -s -r -p "Press any key..."; menu; exit 1; fi
if ! valid_days "$days"; then err "Days must be 1-3650."; read -n1 -s -r -p "Press any key..."; menu; exit 1; fi

cnt=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='ssh' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended','expired');")
[[ "$cnt" -gt 0 ]] || { err "Not a recoverable account."; read -n1 -s -r -p "Press any key..."; menu; exit 1; }

pass=$(db_query "SELECT secret FROM accounts WHERE protocol='ssh' AND username='$(sql_escape "$user")' ORDER BY updated_at DESC LIMIT 1;")
new_epoch=$(( $(date +%s) + days * 86400 ))
exp_system=$(date -d "@${new_epoch}" +%Y-%m-%d)

if id "$user" &>/dev/null; then
  usermod -U "$user" 2>/dev/null || true
  chage -E "$exp_system" "$user" 2>/dev/null
else
  nologin=$(ensure_nologin_shell); [[ -z "$nologin" ]] && nologin=/usr/sbin/nologin
  useradd -e "$exp_system" -M -N -s "$nologin" "$user" || { err "useradd failed"; read -n1 -s -r -p "Press any key..."; menu; exit 1; }
  echo "${user}:${pass}" | chpasswd
fi

db_set_expired "ssh" "$user" "$new_epoch"
db_audit "recover" "ssh" "$user" "+${days}d"
ok "Recovered '$user' (expires in ${days} days)."
line
read -n 1 -s -r -p "Press any key to menu..."
menu
