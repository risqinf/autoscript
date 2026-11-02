#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: List SSH accounts with All-Protocol Quota Usage
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

db_init
clear
line
echo -e "${WHITE}  SSH ACCOUNT LIST (ALL-PROTOCOL QUOTA)${NC}"
line
printf "%-16s %-20s %-18s %-6s %-10s\n" "USERNAME" "EXPIRED" "USED / QUOTA" "IP" "STATUS"
echo "--------------------------------------------------------------------------"
total=0
while IFS='|' read -r u e ub qb ip s; do
  [[ -z "$u" ]] && continue
  u_str=$(human_bytes "${ub:-0}")
  [[ "${qb:-0}" == "0" ]] && q_str="Unl" || q_str=$(human_bytes "$qb")
  printf "%-16s %-20s %-18s %-6s %-10s\n" "$u" "$e" "${u_str}/${q_str}" "$ip" "$s"
  total=$((total+1))
done < <(db_query "SELECT username, datetime(expired_at,'unixepoch','localtime'), used_bytes, quota_bytes, limit_ip, status
                   FROM accounts WHERE protocol='ssh' AND status!='deleted'
                   ORDER BY username;")
line
echo -e "Total: ${total} account(s)"
line
read -n 1 -s -r -p "Press any key to menu..."
menu
