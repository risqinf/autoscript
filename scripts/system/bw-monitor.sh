#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Bandwidth Usage Monitor via vnstat
#              Daily / Weekly / Monthly / Yearly history
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================

[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

if [[ -z "${CYAN:-}" ]]; then
    NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'
    YELLOW='\033[0;33m'; PURPLE='\033[0;35m'; CYAN='\033[0;36m'
    LIGHT='\033[0;37m'
fi

bw_line() { echo -e "${CYAN}--------------------------------------------------------------${NC}"; }
bw_sec()  { echo -e "\n  ${PURPLE}>> $1${NC}"; bw_line; }

bw_iface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$iface" ]] && iface=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)
    echo "${iface:-eth0}"
}

bw_monitor_show() {
    clear
    ui_header "BANDWIDTH MONITOR"

    local iface
    iface=$(bw_iface)
    echo -e "  Interface  : ${GREEN}${iface}${NC}"
    echo -e "  Updated    : ${GREEN}$(date '+%Y-%m-%d %H:%M:%S')${NC}"

    bw_sec "TOTAL SUMMARY"
    vnstat -i "$iface" 2>/dev/null | awk '
    /^[[:space:]]*rx/    { printf "  %-13s : '"${GREEN}"'%s %s'"${NC}"'\n", "Received",    $2, $3 }
    /^[[:space:]]*tx/    { printf "  %-13s : '"${GREEN}"'%s %s'"${NC}"'\n", "Transmitted", $2, $3 }
    /^[[:space:]]*total/ { printf "  %-13s : '"${GREEN}"'%s %s'"${NC}"'\n", "Total",       $2, $3 }
    '
    vnstat -i "$iface" 2>/dev/null | awk '/estimated/ {
        printf "  %-13s : '"${GREEN}"'%s %s%s'"${NC}"'\n", "Est. Monthly", $2, $3, ($4==""?"":" "$4)
    }'

    bw_sec "DAILY HISTORY (30 Hari)"
    printf "  ${LIGHT}%-14s %-14s %-14s %-14s${NC}\n" "Date" "RX" "TX" "Total"
    bw_line
    vnstat -i "$iface" -d 30 2>/dev/null | awk '
    /^[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}/{
        printf "  %-14s %-14s %-14s %-14s\n", $1, $2" "$3, $4" "$5, $6" "$7
    }'

    bw_sec "WEEKLY HISTORY (12 Minggu)"
    printf "  ${LIGHT}%-14s %-14s %-14s %-14s${NC}\n" "Week" "RX" "TX" "Total"
    bw_line
    vnstat -i "$iface" -w 12 2>/dev/null | awk '
    /^[[:space:]]+[0-9]{4}-W[0-9]{2}/{
        w=$1; sub(/.*W/,"W",w)
        printf "  %-14s %-14s %-14s %-14s\n", w, $2" "$3, $4" "$5, $6" "$7
    }'

    bw_sec "MONTHLY HISTORY (24 Bulan)"
    printf "  ${LIGHT}%-12s %-14s %-14s %-14s${NC}\n" "Month" "RX" "TX" "Total"
    bw_line
    vnstat -i "$iface" -m 24 2>/dev/null | awk '
    /^[[:space:]]+(Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)/{
        printf "  %-12s %-14s %-14s %-14s\n", $1" "$2, $3" "$4, $5" "$6, $7" "$8
    }'

    bw_sec "YEARLY HISTORY"
    printf "  ${LIGHT}%-8s %-14s %-14s %-14s${NC}\n" "Year" "RX" "TX" "Total"
    bw_line
    vnstat -i "$iface" -y 2>/dev/null | awk '
    /^[[:space:]]+[0-9]{4}/{
        printf "  %-8s %-14s %-14s %-14s\n", $1, $2" "$3, $4" "$5, $6" "$7
    }'

    bw_sec "TOP 10 DAYS"
    printf "  ${LIGHT}%-14s %-14s %-14s %-14s${NC}\n" "Date" "RX" "TX" "Total"
    bw_line
    vnstat -i "$iface" -t 10 2>/dev/null | awk '
    /^[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}/{
        printf "  %-14s %-14s %-14s %-14s\n", $1, $2" "$3, $4" "$5, $6" "$7
    }'

    echo ""
    bw_line
    echo -e "  Data source: ${CYAN}vnstat${NC}  |  Database: ${CYAN}/var/lib/vnstat/${NC}"
    bw_line
    ui_back
}

if ! command -v vnstat &>/dev/null; then
    echo -e "  ${RED}[ERROR]${NC} vnstat belum terinstall."
    echo ""
    read -rp "  Tekan [Enter] untuk kembali..."
else
    if ! systemctl is-active --quiet vnstat 2>/dev/null; then
        systemctl start vnstat 2>/dev/null
    fi
    bw_monitor_show
fi
