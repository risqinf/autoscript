#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# ========================================================

# --- Database library (SQLite) ---
[[ -f /usr/local/sbin/lib/db.sh ]] && . /usr/local/sbin/lib/db.sh && db_init 2>/dev/null

# --- Color Definitions ---
NC='\033[0m' # No Color
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
PURPLE='\033[1;35m'
LIGHT='\033[0;37m'
BICyan='\033[1;96m'
BIWhite='\033[1;97m'

# --- Function: Delete All Recovery data ---
delall() {
    clear
    line
    echo -e "${WHITE}  PURGE ALL RECOVERY (deleted/expired) ACCOUNTS${NC}"
    line
    echo ""
    echo -e "${YELLOW}WARNING: This permanently removes all soft-deleted/expired${NC}"
    echo -e "${YELLOW}account records from the database. They cannot be recovered.${NC}"
    echo ""

    local total
    total=$(db_query "SELECT COUNT(*) FROM accounts WHERE status IN ('deleted','expired');" 2>/dev/null)
    total=${total:-0}

    if [[ "$total" -eq 0 ]]; then
        warn "No recoverable (deleted/expired) accounts found."
        line
        read -n 1 -s -r -p "Press any key to return to menu..."
        menu
        return 0
    fi

    echo -e "Recoverable records to purge: ${RED}${total}${NC}"
    db_query "SELECT protocol||'  '||username||'  ('||status||')'
              FROM accounts WHERE status IN ('deleted','expired') ORDER BY protocol;" \
      | while read -r row; do echo -e "  ${GREEN}-${NC} $row"; done
    line
    read -rp $'\e[1;31mPurge ALL these records permanently? (yes/NO): \e[0m' confirm
    case "$confirm" in
        yes|YES|Yes)
            db_exec "DELETE FROM accounts WHERE status IN ('deleted','expired');"
            db_audit "purge_recovery" "" "" "count=${total}"
            ok "Purged ${total} recovery records."
            ;;
        *) warn "Cancelled. Nothing was purged." ;;
    esac
    line
    read -n 1 -s -r -p "Press any key to return to menu..."
    menu
}

# --- Function: Clear RAM Cache ---
run_cc() {
    sync
    echo 1 > /proc/sys/vm/drop_caches
    sync
    echo 2 > /proc/sys/vm/drop_caches
    sync
    echo 3 > /proc/sys/vm/drop_caches
}

# --- Bandwidth Usage (vnstat) ---
read_vnstat_usage() {
  local interface=$1
  local today=$(vnstat -i "$interface" 2>/dev/null | grep "today" | awk '{print $8" "$9}')
  local yesterday=$(vnstat -i "$interface" 2>/dev/null | grep "yesterday" | awk '{print $8" "$9}')
  local this_month=$(vnstat -i "$interface" -m 2>/dev/null | grep "$(date +"%b '%y")" | awk '{print $9" "$10}')
  echo "$today;$yesterday;$this_month"
}

convert_to_mb() {
  local value=$1
  local unit=$2
  case $unit in
    B) echo "scale=6; $value / 1048576" | bc ;;
    KiB) echo "scale=6; $value / 1024" | bc ;;
    MiB) echo "$value" ;;
    GiB) echo "scale=6; $value * 1024" | bc ;;
    TiB) echo "scale=6; $value * 1048576" | bc ;;
    *) echo "0" ;;
  esac
}

all_interfaces=$(vnstat --iflist 2>/dev/null | sed 's/Available interfaces: //')
if [ -z "$all_interfaces" ]; then
  ttoday="N/A"
  tyest="N/A"
  tmon="N/A"
else
  total_today=0
  total_yesterday=0
  total_month=0

  for iface in $all_interfaces; do
    result=$(read_vnstat_usage "$iface")
    today=$(echo "$result" | awk -F';' '{print $1}')
    yesterday=$(echo "$result" | awk -F';' '{print $2}')
    month=$(echo "$result" | awk -F';' '{print $3}')
    
    today_value=$(echo "$today" | awk '{print $1}')
    today_unit=$(echo "$today" | awk '{print $2}')
    yesterday_value=$(echo "$yesterday" | awk '{print $1}')
    yesterday_unit=$(echo "$yesterday" | awk '{print $2}')
    month_value=$(echo "$month" | awk '{print $1}')
    month_unit=$(echo "$month" | awk '{print $2}')
    
    total_today=$(echo "$total_today + $(convert_to_mb $today_value $today_unit)" | bc)
    total_yesterday=$(echo "$total_yesterday + $(convert_to_mb $yesterday_value $yesterday_unit)" | bc)
    total_month=$(echo "$total_month + $(convert_to_mb $month_value $month_unit)" | bc)
  done

  format_usage() {
    local value=$1
    if (( $(echo "$value >= 1024" | bc -l) )); then
      echo "$(printf "%.2f" $(echo "$value / 1024" | bc)) GB"
    else
      echo "$(printf "%.2f" $value) MB"
    fi
  }

  ttoday=$(format_usage "$total_today")
  tyest=$(format_usage "$total_yesterday")
  tmon=$(format_usage "$total_month")
fi

# --- TOTAL ACCOUNT COUNT (DB-driven) ---
ssh1=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='ssh' AND status!='deleted';" 2>/dev/null); ssh1=${ssh1:-0}
vls=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='vless' AND status!='deleted';" 2>/dev/null); vls=${vls:-0}
vms=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='vmess' AND status!='deleted';" 2>/dev/null); vms=${vms:-0}
tro=$(db_query "SELECT COUNT(*) FROM accounts WHERE protocol='trojan' AND status!='deleted';" 2>/dev/null); tro=${tro:-0}

# --- SERVICE STATUS (uses shared badges from common.sh) ---
# SSH tunnel = dropbear + ssh-ws together (3-state: ON/WARN/OFF).
ressshws=$(ssh_stack_badge)
resngx=$(svc_badge nginx)
resv2r=$(svc_badge xray)
reshap=$(svc_badge haproxy)
resovpn=$(svc_badge openvpn-server@server-tcp-1194)

# --- SYSTEM INFO ---
DOMAIN=$(cat /etc/xray/domain 2>/dev/null || echo "Not Set")
cname=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
cores=$(awk -F: '/model name/ {core++} END {print core}' /proc/cpuinfo)
freq=$(awk -F: ' /cpu MHz/ {freq=$2} END {print freq}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
tram=$(free -m | awk 'NR==2 {print $2}')
up=$(uptime -p | sed 's/up //')
OS1=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Unknown OS")
f1=$(. /etc/os-release 2>/dev/null && echo "$VERSION_ID" || echo "N/A")
frem=$(free -h | grep "Mem:" | awk '{print $3 "/" $2}')
freswp=$(free -h | grep "Swap:" | awk '{print $3 "/" $2}')
cpu=$(top -bn1 | grep "Cpu(s)" | awk '{print $8"% idle"}')
xray_version=$(xray version 2>/dev/null | awk 'NR==1 {print $1, $2}' || echo "Not Installed")
IPVPS=$(curl -s ifconfig.me 2>/dev/null || echo "N/A")

# --- MAIN MENU ---
clear
ui_header "ENTERPRISE VPN MANAGER"
ui_kv "OS"       "$OS1"
ui_kv "IP"       "$IPVPS"
ui_kv "Domain"   "$DOMAIN"
ui_kv "Uptime"   "$up"
ui_kv "RAM"      "$frem"
ui_kv "CPU"      "$cpu"
ui_kv "Traffic"  "$ttoday / $tyest / $tmon  (day/yest/mon)"
ui_rule
printf " ${WHITE}%-12s${NC} ${CYAN}:${NC} SSH ${GREEN}%s${NC}   VLESS ${GREEN}%s${NC}   VMESS ${GREEN}%s${NC}   TROJAN ${GREEN}%s${NC}\n" "Accounts" "$ssh1" "$vls" "$vms" "$tro"
ui_rule
ui_label "SERVICES"
ui_status "SSH + WS"  "$ressshws"
ui_status "Xray Core" "$resv2r"
ui_status "Nginx"     "$resngx"
ui_status "HAProxy"   "$reshap"
ui_status "OpenVPN"   "$resovpn"
ui_rule
ui_label "ACCOUNT PANELS"
ui_opt 1 "SSH / OpenVPN Panel"
ui_opt 2 "VLESS Panel"
ui_opt 3 "VMESS Panel"
ui_opt 4 "TROJAN Panel"
ui_rule
ui_label "TOOLS"
ui_opt 5 "Auto Bulk Create"
ui_opt 6 "Account Cleaner"
ui_opt 7 "User Checker"
ui_opt 8 "API Menu"
ui_rule
ui_label "SERVER"
ui_opt 9  "System Menu"
ui_opt 10 "Backup / Restore"
ui_opt x  "Exit"
ui_rule
ui_kv "Xray" "$xray_version"
ui_foot

# --- MENU SELECTION ---
read -p " Select Option : " mm
case $mm in
1) clear ; run_cc ; menu-ssh ;;
2) clear ; run_cc ; menu-vless ;;
3) clear ; run_cc ; menu-vmess ;;
4) clear ; run_cc ; menu-trojan ;;
5) clear ; run_cc ; add-bulk ;;
6) clear ; run_cc ; delall ;;
7) clear ; run_cc ; cek-user ;;
8) clear ; run_cc ; menu-api ;;
9) clear ; run_cc ; menu-system ;;
10) clear ; run_cc ; menu-backup ;;
x|X) clear ; exit 0 ;;
00) clear ; run_cc ; nano /etc/issue.net ;;
*) echo "Invalid option, please try again." ; sleep 1 ; menu ;;
esac