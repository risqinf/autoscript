#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Live User & Device Checker for NoobzVPN
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/common.sh

require_root

DB_JSON="/etc/noobzvpns/db_user.json"

clear
ui_header "NOOBZVPN LIVE USER MONITOR"

if [[ ! -f "$DB_JSON" || ! -s "$DB_JSON" ]]; then
  if command -v noobzvpns &>/dev/null; then
    echo -e " ${YELLOW}Reading from noobzvpns CLI...${NC}"
    noobzvpns print-all 2>/dev/null || echo -e " ${RED}No active data available.${NC}"
  else
    warn "Database $DB_JSON not found or empty."
  fi
  ui_back
  menu
  exit 0
fi

fmt_bytes() {
  local b="${1:-0}"
  if (( $(echo "$b >= 1073741824" | bc -l 2>/dev/null || echo 0) )); then
    printf "%.2f GB" "$(echo "$b / 1073741824" | bc -l 2>/dev/null)"
  elif (( $(echo "$b >= 1048576" | bc -l 2>/dev/null || echo 0) )); then
    printf "%.2f MB" "$(echo "$b / 1048576" | bc -l 2>/dev/null)"
  elif (( $(echo "$b >= 1024" | bc -l 2>/dev/null || echo 0) )); then
    printf "%.2f KB" "$(echo "$b / 1024" | bc -l 2>/dev/null)"
  else
    echo "${b} B"
  fi
}

online_count=0
total_users=0

# Extract user records
mapfile -t users < <(jq -r '.users | keys[]' "$DB_JSON" 2>/dev/null)

for u in "${users[@]}"; do
  [[ -z "$u" ]] && continue
  total_users=$((total_users + 1))

  dev_count=$(jq -r --arg u "$u" '(.users[$u].statistic.active_devices // []) | length' "$DB_JSON" 2>/dev/null)
  dev_count=${dev_count:-0}

  if (( dev_count > 0 )); then
    online_count=$((online_count + 1))
    up_b=$(jq -r --arg u "$u" '.users[$u].statistic.bytes_usage.up // 0' "$DB_JSON" 2>/dev/null)
    down_b=$(jq -r --arg u "$u" '.users[$u].statistic.bytes_usage.down // 0' "$DB_JSON" 2>/dev/null)
    tot_b=$(( up_b + down_b ))
    limit_d=$(jq -r --arg u "$u" '.users[$u].devices // 0' "$DB_JSON" 2>/dev/null)
    [[ "$limit_d" == "0" ]] && limit_d="Unlimited"

    echo -e " ${WHITE}Username      :${NC} ${CYAN}${u}${NC}"
    echo -e " ${WHITE}Status        :${NC} ${GREEN}Online (${dev_count} Device/s)${NC}"
    echo -e " ${WHITE}Limit Device  :${NC} ${limit_d}"
    echo -e " ${WHITE}Usage Upload  :${NC} $(fmt_bytes "$up_b")"
    echo -e " ${WHITE}Usage Download:${NC} $(fmt_bytes "$down_b")"
    echo -e " ${WHITE}Total Usage   :${NC} $(fmt_bytes "$tot_b")"

    # Display active device IDs
    mapfile -t dev_hashes < <(jq -r --arg u "$u" '(.users[$u].statistic.active_devices // [])[]' "$DB_JSON" 2>/dev/null)
    if [[ ${#dev_hashes[@]} -gt 0 ]]; then
      echo -e " ${WHITE}Active Device Hashes :${NC}"
      for dh in "${dev_hashes[@]}"; do
        echo -e "   ${PINK}•${NC} ${dh}"
      done
    fi
    ui_rule
  fi
done

if (( online_count == 0 )); then
  echo -e " ${YELLOW}No users currently online.${NC}"
  echo -e " ${WHITE}Total registered accounts:${NC} ${total_users}"
  ui_rule
else
  echo -e " ${WHITE}Total Online :${NC} ${GREEN}${online_count}${NC} User(s) / ${total_users} Total"
  ui_rule
fi

ui_back
menu
