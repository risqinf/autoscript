#!/bin/bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# ========================================================
# ========================================================
# Developed for Rocky Linux 9
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh
# UI Color Codes
RED='\e[1;31m'
GREEN='\e[1;32m'
YELLOW='\e[1;33m'
BLUE='\e[1;34m'
CYAN='\e[1;36m'
NC='\033[0m'
BOLD='\e[1m'

# Loading animation
loading() {
  local msg="$1"
  echo -ne "${CYAN}$msg"
  for i in {1..3}; do
    echo -ne "."
    sleep 0.5
  done
  echo -e "${NC}"
}

menu-api() {
clear
generate() {
  clear
  loading "${YELLOW}Generating New Key"
  # Generate a 32-character random alphanumeric API key dengan prefix risqinf_
  newkey="risqinf_$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
  # Hindari duplikat, tambahkan hanya jika belum ada
  grep -qxF "$newkey" /etc/api/key 2>/dev/null || echo "$newkey" >> /etc/api/key
  systemctl daemon-reload
  systemctl enable api-server.service
  systemctl start api-server.service
  systemctl restart api-server.service
  mds=$(cat /etc/api/key)
  clear
  echo -e "${GREEN}${BOLD}[OK] Success Generate New Key${NC}"
  ui_rule
  echo -e "${YELLOW}Your API Token:${NC}"
  echo -e "${BOLD}$newkey${NC}"
  ui_rule
  read -n 1 -s -r -p "Press any key to return to menu..."
}

manual() {
  clear
  echo -e "${YELLOW}Add New Token API${NC}"
  ui_rule
  read -p "Input Token: " token
  loading "${YELLOW}Adding Token"
  echo $token >> /etc/api/key
  systemctl daemon-reload
  systemctl enable api-server.service
  systemctl start api-server.service
  systemctl restart api-server.service
  mds=$(cat /etc/api/key)
  clear
  echo -e "${GREEN}${BOLD}[OK] Success Add New Key API${NC}"
  ui_rule
  echo -e "${YELLOW}Your API Token:${NC}"
  echo -e "${BOLD}$mds${NC}"
  ui_rule
  read -n 1 -s -r -p "Press any key to return to menu..."
}

manual31() {
  nano /etc/api/key
}

enable() {
  clear
  loading "${YELLOW}Enabling API"
  systemctl daemon-reload
  systemctl enable api-server.service
  systemctl start api-server.service
  systemctl restart api-server.service
  clear
  echo -e "${GREEN}${BOLD}[OK] Done Enable API${NC}"
  read -n 1 -s -r -p "Press any key to return to menu..."
}

restart() {
  loading "${YELLOW}Restarting API"
  systemctl daemon-reload
  systemctl enable api-server.service
  systemctl start api-server.service
  systemctl restart api-server.service
  clear
  echo -e "${GREEN}${BOLD}[OK] Done Restarting API${NC}"
  read -n 1 -s -r -p "Press any key to return to menu..."
}

disable() {
  loading "${RED}Disabling API"
  systemctl stop api-server.service
  systemctl disable api-server.service
  clear
  echo -e "${RED}${BOLD}[X] Success Disable API${NC}"
  read -n 1 -s -r -p "Press any key to return to menu..."
}

detail() {
  mkdir -p /etc/api
  domain=$(cat /etc/xray/domain)

  while true; do
    clear
    edust_service=$(systemctl is-active api-server.service 2>/dev/null)
    if [[ $edust_service == "active" ]]; then
      proxy1="${GREEN}ONLINE${NC}"
    else
      proxy1="${RED}OFFLINE${NC}"
    fi

    ui_header "WEB API PANEL"
    echo -e " Status : $proxy1"
    echo -e " Domain : ${CYAN}${domain}${NC}"
    ui_rule
    echo -e " Endpoints :"
    echo -e "   http(s)://${domain}/api/accounts/ssh"
    echo -e "   http(s)://${domain}/api/health"
    echo -e "   http://${domain}:9000/api/status"
    ui_rule
    ui_opt 1 "Generate New Key Token"
    ui_opt 2 "Change Manual Key Token (edit file)"
    ui_opt 3 "Add Key Token API"
    ui_opt 4 "Enable API"
    ui_opt 5 "Restart API"
    ui_opt 6 "Disable API"
    ui_rule
    ui_opt 0 "Back to Main Menu"
    ui_foot
    read -rp " Select option [0-6]: " opw

    case $opw in
      1) generate ;;
      2) manual31 ;;
      3) manual ;;
      4) enable ;;
      5) restart ;;
      6) disable ;;
      0|x|X) clear ; exec menu ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

detail

}

menu-api