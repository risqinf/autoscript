#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Recover (restore) deleted/suspended VMESS account
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

require_root
db_init

clear
line
echo -e "${WHITE}  RECOVERY VMESS ACCOUNT${NC}"
line
printf "%-20s %-22s %-10s\n" "USERNAME" "EXPIRED" "STATUS"
echo "------------------------------------------------------------"
total=0
while IFS='|' read -r u e s; do
  [[ -z "$u" ]] && continue
  printf "%-20s %-22s %-10s\n" "$u" "$e" "$s"
  total=$((total+1))
done < <(db_query "SELECT username, datetime(expired_at,'unixepoch','localtime'), status
                   FROM accounts WHERE protocol='vmess' AND status IN ('deleted','suspended')
                   ORDER BY updated_at DESC;")
line
if [[ $total -eq 0 ]]; then
  warn "No recoverable VMESS accounts."
  read -n 1 -s -r -p "Press any key to menu..."; menu; exit 0
fi

read -rp "Enter username to recover: " user
if ! valid_username "$user"; then err "Invalid username."; read -n1 -s -r -p "Press any key..."; menu; exit 1; fi

cnt=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='vmess' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended');")
[[ "$cnt" -gt 0 ]] || { err "Not a recoverable account."; read -n1 -s -r -p "Press any key..."; menu; exit 1; }

# Refuse if username already active again (avoid collisions).
if cfg_client_exists "$user"; then
  err "An active client with this username already exists."; read -n1 -s -r -p "Press any key..."; menu; exit 1
fi

uuid=$(db_query "SELECT secret FROM accounts WHERE protocol='vmess' AND username='$(sql_escape "$user")' AND status IN ('deleted','suspended') ORDER BY updated_at DESC LIMIT 1;")
if cfg_add_client "vmess" "$user" "$uuid"; then
  db_exec "UPDATE accounts SET status='active', updated_at=strftime('%s','now')
           WHERE protocol='vmess' AND username='$(sql_escape "$user")';"
  db_audit "recover" "vmess" "$user" ""
  systemctl restart xray.service >/dev/null 2>&1
  tg_send "<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>%0A<b>    ⊹ VMESS UNBANNED / RECOVERED ⊹</b>%0A<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>%0A<b>Username :</b> <code>${user}</code>%0A<b>Protocol :</b> <code>VMESS</code>%0A<b>Status   :</b> <b>ACTIVE (Dipulihkan)</b>%0A<b>Action   :</b> <code>Dipulihkan via CLI</code>%0A<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>"
  ok "Recovered '$user'."
else
  err "Failed to restore into config."
fi
line
read -n 1 -s -r -p "Press any key to menu..."
menu
