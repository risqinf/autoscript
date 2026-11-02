#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Live User & Device Checker for NoobzVPN (with GeoIP & Usage)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/account.sh

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

# Collect live peer IPs connected to port 8585 (NoobzVPN TCP)
mapfile -t NOOBZ_IPS < <(ss -tnH state established '( sport = :8585 )' 2>/dev/null | awk '{ip=$5; sub(/^::ffff:/,"",ip); sub(/:[0-9]+$/,"",ip); if(ip!="" && ip!~"^127\\.") print ip}' | sort -u)

online_count=0
total_users=0

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
    [[ "$up_b" =~ ^[0-9]+$ ]] || up_b=0
    [[ "$down_b" =~ ^[0-9]+$ ]] || down_b=0
    tot_b=$(( up_b + down_b ))
    limit_d=$(jq -r --arg u "$u" '.users[$u].devices // 0' "$DB_JSON" 2>/dev/null)
    [[ "$limit_d" == "0" ]] && limit_d="Unlimited"

    ui_kv "Username"      "$u" "$CYAN"
    ui_kv "Protocol"      "NOOBZVPN (TCP/WS)" "$PINK"
    ui_kv "Status"        "Online (${dev_count} Device/s)" "$GREEN"
    ui_kv "Limit Device"  "$limit_d"
    ui_kv "Usage Upload"  "$(human_bytes "$up_b")"
    ui_kv "Usage Download" "$(human_bytes "$down_b")"
    ui_kv "Total Usage"   "$(human_bytes "$tot_b")"

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

if [[ ${#NOOBZ_IPS[@]} -gt 0 ]]; then
  echo -e " ${WHITE}Connected Client IPs (Port 8585) :${NC}"
  for nip in "${NOOBZ_IPS[@]}"; do
    geo=$(lookup_ip_geo "$nip")
    echo -e "   ${GREEN}- ${nip}${NC} ${YELLOW}[ ${geo%%|*} ]${NC} ${CYAN}(${geo#*|})${NC}"
  done
  ui_rule
fi

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
