#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SlowDNS (DNSTT) Manager Submenu
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh || . "$(dirname "$0")/../lib/common.sh"

require_root

menu_slowdns() {
  clear
  ui_header "SLOWDNS (DNSTT) MANAGER"

  local status_badge; status_badge=$(svc_badge slowdns)
  local ns; ns=$(cat /etc/slowdns/nameserver 2>/dev/null)
  [[ -z "$ns" ]] && ns="${YELLOW}(not configured)${NC}"

  local pub; pub=$(cat /etc/slowdns/server.pub 2>/dev/null)
  [[ -z "$pub" ]] && pub="${YELLOW}(not generated)${NC}"

  ui_status "SlowDNS Status" "$status_badge"
  ui_kv "Nameserver" "$ns"
  ui_kv "Public Key" "$pub"
  ui_kv "Port" "53 / 5300 UDP"
  ui_kv "Target" "Dropbear SSH (127.0.0.1:109)"
  ui_rule

  ui_opt 1 "Start / Restart SlowDNS"
  ui_opt 2 "Stop SlowDNS"
  ui_opt 3 "Change Nameserver"
  ui_opt 4 "Regenerate Keypair"
  ui_opt 5 "Install / Reinstall SlowDNS"
  ui_opt 6 "Uninstall SlowDNS"
  ui_rule
  ui_opt 0 "Back to SSH Menu"
  ui_foot

  read -rp " Select option : " opt
  case "$opt" in
    1)
      clear
      slowdns start || slowdns restart
      ui_back
      menu_slowdns
      ;;
    2)
      clear
      slowdns stop
      ui_back
      menu_slowdns
      ;;
    3)
      clear
      slowdns change-ns
      ui_back
      menu_slowdns
      ;;
    4)
      clear
      slowdns regen-key
      ui_back
      menu_slowdns
      ;;
    5)
      clear
      slowdns install
      ui_back
      menu_slowdns
      ;;
    6)
      clear
      slowdns uninstall
      ui_back
      menu_slowdns
      ;;
    0|x|X)
      if command -v menu-ssh &>/dev/null; then
        menu-ssh
      elif [[ -f /usr/local/sbin/menu/menu-ssh.sh ]]; then
        /usr/local/sbin/menu/menu-ssh.sh
      elif [[ -f "$(dirname "$0")/menu-ssh.sh" ]]; then
        "$(dirname "$0")/menu-ssh.sh"
      else
        menu
      fi
      ;;
    *)
      err "Invalid option."
      sleep 1
      menu_slowdns
      ;;
  esac
}

menu_slowdns
