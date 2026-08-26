#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: RESTful API Management Menu (SQLite & Token Integrated)
# Developed for Rocky Linux 9 / Enterprise Linux
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

API_DB="/etc/api/api.db"
API_SERVICE="api-server.service"

get_active_token() {
  if [[ -f "$API_DB" ]] && command -v sqlite3 &>/dev/null; then
    local tok
    tok=$(sqlite3 "$API_DB" "SELECT token FROM tokens ORDER BY id DESC LIMIT 1;" 2>/dev/null)
    if [[ -n "$tok" ]]; then
      echo "$tok"
      return 0
    fi
  fi
  if [[ -f /etc/api/key ]]; then
    head -n 1 /etc/api/key | tr -d '\r\n'
    return 0
  fi
  echo ""
}

show_api_details() {
  clear
  local domain="127.0.0.1"
  [[ -f /etc/xray/domain ]] && domain=$(cat /etc/xray/domain)
  local token; token=$(get_active_token)

  ui_header "API CREDENTIALS & ENDPOINTS"
  echo -e " ${WHITE}Base URL (Local)${NC}   : ${CYAN}http://127.0.0.1:9000${NC}"
  echo -e " ${WHITE}Base URL (Public)${NC}  : ${CYAN}https://${domain}${NC}"
  echo -e " ${WHITE}Health Check${NC}       : ${CYAN}https://${domain}/api/health${NC} (no auth)"
  ui_rule
  if [[ -n "$token" ]]; then
    echo -e " ${YELLOW}Active Bearer Token:${NC}"
    echo -e " ${GREEN}${BOLD}${token}${NC}"
    ui_rule
    echo -e " ${WHITE}Example cURL Request:${NC}"
    echo -e " ${CYAN}curl -H \"Authorization: Bearer ${token}\" https://${domain}/api/status${NC}"
  else
    echo -e " ${RED}[!] No active token found in /etc/api/api.db.${NC}"
    echo -e " ${YELLOW}Please select 'Revoke & Generate New Token' to create one.${NC}"
  fi
  ui_foot
  read -n 1 -s -r -p " Press any key to return..."
}

revoke_and_generate_token() {
  clear
  ui_header "REVOKE & GENERATE API TOKEN"
  echo -e " ${YELLOW}WARNING:${NC} Revoking will invalidate the current token."
  echo -e " All external apps (web panels/bots) must use the new token."
  echo ""
  read -rp " Are you sure you want to revoke and generate a new token? [y/N]: " confirm
  if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
    echo " Operation cancelled."
    sleep 1
    return 0
  fi

  echo ""
  echo -ne " ${CYAN}Generating cryptographically secure 64-hex token...${NC}"
  local new_token
  if command -v openssl &>/dev/null; then
    new_token=$(openssl rand -hex 32)
  else
    new_token=$(tr -dc 'a-f0-9' </dev/urandom | head -c 64)
  fi

  mkdir -p /etc/api
  chmod 700 /etc/api

  if command -v sqlite3 &>/dev/null; then
    sqlite3 "$API_DB" "CREATE TABLE IF NOT EXISTS tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      token TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
      last_used INTEGER NOT NULL DEFAULT 0
    );" 2>/dev/null
    sqlite3 "$API_DB" "DELETE FROM tokens;" 2>/dev/null
    sqlite3 "$API_DB" "INSERT INTO tokens (name, token, created_at) VALUES ('default', '$new_token', strftime('%s','now'));" 2>/dev/null
  fi

  # Backup to /etc/api/key for legacy compatibility
  echo "$new_token" > /etc/api/key
  chmod 600 /etc/api/key

  echo -e " ${GREEN}[OK]${NC}"
  echo -ne " ${CYAN}Restarting API Server service...${NC}"
  systemctl restart "$API_SERVICE" 2>/dev/null || true
  sleep 1
  echo -e " ${GREEN}[OK]${NC}"

  clear
  ui_header "NEW TOKEN GENERATED"
  echo -e " ${GREEN}${BOLD}[SUCCESS] API Token has been regenerated!${NC}"
  ui_rule
  echo -e " ${YELLOW}New Bearer Token:${NC}"
  echo -e " ${GREEN}${BOLD}${new_token}${NC}"
  ui_rule
  echo -e " ${WHITE}Please update your VPN website / bot .env settings immediately.${NC}"
  ui_foot
  read -n 1 -s -r -p " Press any key to return..."
}

restart_api_service() {
  clear
  ui_header "RESTART API SERVER"
  echo -ne " ${CYAN}Restarting ${API_SERVICE}...${NC}"
  systemctl daemon-reload
  systemctl restart "$API_SERVICE" 2>/dev/null
  sleep 1

  if systemctl is-active --quiet "$API_SERVICE"; then
    echo -e " ${GREEN}[OK ONLINE]${NC}"
  else
    echo -e " ${RED}[FAILED OFFLINE]${NC}"
    echo -e " ${YELLOW}Check logs with: journalctl -u api-server -n 20${NC}"
  fi
  ui_foot
  read -n 1 -s -r -p " Press any key to return..."
}

install_api_service() {
  clear
  if [[ -f /usr/local/sbin/install-api ]]; then
    bash /usr/local/sbin/install-api
  elif [[ -f /root/autoscript/install-api.sh ]]; then
    bash /root/autoscript/install-api.sh
  else
    curl -fsSL https://raw.githubusercontent.com/risqinf/autoscript/main/install-api.sh | bash
  fi
  read -n 1 -s -r -p " Press any key to return..."
}

uninstall_api_service() {
  clear
  if [[ -f /usr/local/sbin/uninstall-api ]]; then
    bash /usr/local/sbin/uninstall-api
  elif [[ -f /root/autoscript/uninstall-api.sh ]]; then
    bash /root/autoscript/uninstall-api.sh
  else
    curl -fsSL https://raw.githubusercontent.com/risqinf/autoscript/main/uninstall-api.sh | bash
  fi
  read -n 1 -s -r -p " Press any key to return..."
}

menu-api() {
  while true; do
    clear
    local is_active; is_active=$(systemctl is-active "$API_SERVICE" 2>/dev/null || echo "inactive")
    local status_display
    if [[ "$is_active" == "active" ]]; then
      status_display="${GREEN}${BOLD}ONLINE (active)${NC}"
    else
      status_display="${RED}${BOLD}OFFLINE (stopped)${NC}"
    fi

    local domain="127.0.0.1"
    [[ -f /etc/xray/domain ]] && domain=$(cat /etc/xray/domain)

    local current_token; current_token=$(get_active_token)
    local token_short="None (not initialized)"
    if [[ -n "$current_token" ]]; then
      if (( ${#current_token} > 24 )); then
        token_short="${current_token:0:16}...${current_token: -8}"
      else
        token_short="$current_token"
      fi
    fi

    ui_header "RESTful API MANAGEMENT PANEL"
    echo -e " ${WHITE}Service Status${NC} : $status_display"
    echo -e " ${WHITE}Domain / Host${NC}  : ${CYAN}${domain}${NC} (Port 9000 / 80 / 443)"
    echo -e " ${WHITE}Active Token${NC}   : ${GREEN}${token_short}${NC}"
    ui_rule
    ui_opt 1 "Lihat Token & Detail Endpoints"
    ui_opt 2 "Revoke & Generate Token Baru"
    ui_opt 3 "Restart API Server Service"
    ui_opt 4 "Install / Rebuild API Server"
    ui_opt 5 "Uninstall API Server"
    ui_rule
    ui_opt 0 "Kembali ke Menu Utama"
    ui_foot
    read -rp " Select option [0-5]: " opt

    case "$opt" in
      1) show_api_details ;;
      2) revoke_and_generate_token ;;
      3) restart_api_service ;;
      4) install_api_service ;;
      5) uninstall_api_service ;;
      0|x|X) clear; [[ -f /usr/local/sbin/menu ]] && exec /usr/local/sbin/menu || exit 0 ;;
      *) echo -e " ${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
    esac
  done
}

menu-api