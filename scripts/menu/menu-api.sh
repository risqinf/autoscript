#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: RESTful API Management Menu (Multi-Layer SHA256 + Bearer Token)
# Developed for Rocky Linux 9 / Enterprise Linux
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

API_DB="/etc/api/api.db"
API_SECRET_FILE="/etc/api/secret"
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

get_active_secret() {
  if [[ -s "$API_SECRET_FILE" ]]; then
    head -n 1 "$API_SECRET_FILE" | tr -d '\r\n'
    return 0
  fi
  echo ""
}

show_api_details() {
  clear
  local domain="127.0.0.1"
  [[ -f /etc/xray/domain ]] && domain=$(cat /etc/xray/domain)
  local token; token=$(get_active_token)
  local secret; secret=$(get_active_secret)

  ui_header "API CREDENTIALS & SHA-256 VERIFICATION"
  echo -e " ${WHITE}Base URL (Local)${NC}   : ${CYAN}http://127.0.0.1:9000${NC}"
  echo -e " ${WHITE}Base URL (Public)${NC}  : ${CYAN}https://${domain}${NC}"
  echo -e " ${WHITE}Health Check${NC}       : ${CYAN}https://${domain}/api/health${NC} (public)"
  echo -e " ${WHITE}Verification Mode${NC}  : ${GREEN}STRICT (5-Layer SHA-256 + HMAC-SHA256)${NC}"
  ui_rule
  if [[ -n "$token" ]]; then
    echo -e " ${YELLOW}1. Active Bearer Token (Layer 1):${NC}"
    echo -e " ${GREEN}${token}${NC}"
  else
    echo -e " ${RED}[!] No active Bearer token found.${NC}"
  fi
  echo ""
  if [[ -n "$secret" ]]; then
    echo -e " ${YELLOW}2. Active HMAC Secret Key (Layer 5 SHA-256 Signing):${NC}"
    echo -e " ${GREEN}${secret}${NC}"
  else
    echo -e " ${RED}[!] No HMAC secret key found (/etc/api/secret).${NC}"
  fi
  ui_rule
  if [[ -n "$token" && -n "$secret" ]]; then
    echo -e " ${WHITE}Required Security Headers on Protected Requests:${NC}"
    echo -e "   • ${CYAN}Authorization: Bearer <TOKEN>${NC}"
    echo -e "   • ${CYAN}X-Timestamp: <UNIX_SECONDS>${NC}"
    echo -e "   • ${CYAN}X-Nonce: <UNIQUE_16+_HEX>${NC}"
    echo -e "   • ${CYAN}X-Content-SHA256: <SHA256_HEX_OF_RAW_BODY>${NC}"
    echo -e "   • ${CYAN}X-Signature: <HMAC_SHA256_CANONICAL_SIGNATURE>${NC}"
  fi
  ui_foot
  read -n 1 -s -r -p " Press any key to return..."
}

revoke_and_generate_credentials() {
  clear
  ui_header "ROTATE API TOKEN & HMAC SECRET"
  echo -e " ${YELLOW}WARNING:${NC} Rotating will invalidate the current Bearer Token & HMAC Secret."
  echo -e " All external apps (web panels/bots) must update both credentials."
  echo ""
  read -rp " Are you sure you want to rotate API credentials? [y/N]: " confirm
  if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
    echo " Operation cancelled."
    sleep 1
    return 0
  fi

  echo ""
  echo -ne " ${CYAN}Generating cryptographically secure 256-bit keys...${NC}"
  local new_token new_secret
  if command -v openssl &>/dev/null; then
    new_token=$(openssl rand -hex 32)
    new_secret=$(openssl rand -hex 32)
  else
    new_token=$(tr -dc 'a-f0-9' </dev/urandom | head -c 64)
    new_secret=$(tr -dc 'a-f0-9' </dev/urandom | head -c 64)
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

  echo "$new_token" > /etc/api/key
  echo "$new_secret" > "$API_SECRET_FILE"
  chmod 600 /etc/api/key "$API_SECRET_FILE" "$API_DB" 2>/dev/null || true

  echo -e " ${GREEN}[OK]${NC}"
  echo -ne " ${CYAN}Restarting API Server service...${NC}"
  systemctl restart "$API_SERVICE" 2>/dev/null || true
  sleep 1
  echo -e " ${GREEN}[OK]${NC}"

  clear
  ui_header "NEW API CREDENTIALS GENERATED"
  echo -e " ${GREEN}[SUCCESS] Bearer Token & HMAC Secret Key rotated!${NC}"
  ui_rule
  echo -e " ${YELLOW}Bearer Token:${NC}"
  echo -e " ${GREEN}${new_token}${NC}"
  echo ""
  echo -e " ${YELLOW}HMAC Secret Key (SHA-256 Signing):${NC}"
  echo -e " ${GREEN}${new_secret}${NC}"
  ui_rule
  echo -e " ${WHITE}Update API_TOKEN and API_SECRET in your panel/bot .env immediately.${NC}"
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
    curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/risqinf/autoscript/main/install-api.sh | bash
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
    curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/risqinf/autoscript/main/uninstall-api.sh | bash
  fi
  read -n 1 -s -r -p " Press any key to return..."
}

menu-api() {
  while true; do
    clear
    local is_active; is_active=$(systemctl is-active "$API_SERVICE" 2>/dev/null || echo "inactive")
    local status_display
    if [[ "$is_active" == "active" ]]; then
      status_display="${GREEN}ONLINE (active)${NC}"
    else
      status_display="${RED}OFFLINE (stopped)${NC}"
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

    local current_secret; current_secret=$(get_active_secret)
    local secret_short="None (not initialized)"
    if [[ -n "$current_secret" ]]; then
      if (( ${#current_secret} > 24 )); then
        secret_short="${current_secret:0:16}...${current_secret: -8}"
      else
        secret_short="$current_secret"
      fi
    fi

    ui_header "RESTful API MANAGEMENT PANEL"
    echo -e " ${WHITE}Service Status${NC} : $status_display"
    echo -e " ${WHITE}Domain / Host${NC}  : ${CYAN}${domain}${NC} (Port 9000 / 80 / 443)"
    echo -e " ${WHITE}Bearer Token${NC}   : ${GREEN}${token_short}${NC}"
    echo -e " ${WHITE}HMAC Secret${NC}    : ${GREEN}${secret_short}${NC}"
    echo -e " ${WHITE}Security Layer${NC} : ${PINK}5-Layer Strict SHA-256${NC}"
    ui_rule
    ui_opt 1 "Lihat Token, Secret Key & Detail Endpoints"
    ui_opt 2 "Rotate Token & HMAC Secret Baru"
    ui_opt 3 "Restart API Server Service"
    ui_opt 4 "Install / Rebuild API Server"
    ui_opt 5 "Uninstall API Server"
    ui_rule
    ui_opt 0 "Kembali ke Menu Utama"
    ui_foot
    read -rp " Select option [0-5]: " opt

    case "$opt" in
      1) show_api_details ;;
      2) revoke_and_generate_credentials ;;
      3) restart_api_service ;;
      4) install_api_service ;;
      5) uninstall_api_service ;;
      0|x|X) clear; [[ -f /usr/local/sbin/menu ]] && exec /usr/local/sbin/menu || exit 0 ;;
      *) echo -e " ${RED}Pilihan tidak valid!${NC}"; sleep 1 ;;
    esac
  done
}

menu-api
