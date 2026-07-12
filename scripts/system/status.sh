#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Service status overview + interactive control
#              (start/stop/restart/enable/disable per service)
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
. /usr/local/sbin/lib/common.sh

# unit|label|listen-port  (unit may carry an explicit .timer/.socket suffix;
# bare names default to the .service unit). Port is for quick reference.
ROWS=(
  "haproxy|HAProxy (entry)|80, 443"
  "nginx|Nginx (router)|81*"
  "xray|Xray Core|1,2,3*"
  "dropbear|Dropbear SSH|109"
  "ssh-ws|SSH WebSocket|8888"
  "sshd|OpenSSH|22, 3303"
  "openvpn-server@server-tcp-1194|OpenVPN TCP|1194"
  "api-server|API Server|9000*"
  "vnstat|vnStat (bandwidth)|-"
  "rsyslog|rsyslog (secure)|-"
  "firewalld|Firewall|-"
  "quota|VLESS quota loop|-"
  "limit-ip-vless|VLESS ip-limit|-"
  "quota-vmess|VMESS quota loop|-"
  "limit-ip-vmess|VMESS ip-limit|-"
  "quota-trojan|Trojan quota loop|-"
  "limit-ip-trojan|Trojan ip-limit|-"
  "autoexpire.timer|Auto-expire (timer)|-"
  "limit-ip-ssh.timer|SSH ip-limit (timer)|-"
  "backup.timer|Backup (timer)|-"
  "fixlog.timer|Log cleanup (timer)|-"
)

# Services whose stop/disable can cut SSH or web access -> require confirmation.
is_critical() {
  case "$1" in
    sshd|haproxy|nginx|dropbear|ssh-ws|firewalld) return 0 ;;
    *) return 1 ;;
  esac
}

# Resolve a row "unit" token to a full systemd unit name (adds .service if no
# explicit suffix is present).
unit_file() { case "$1" in *.*) echo "$1" ;; *) echo "$1.service" ;; esac; }

# Is the unit known to systemd (installed)? Template instances (foo@bar) and
# active units are always treated as present.
unit_installed() {
  local uf; uf="$(unit_file "$1")"
  systemctl list-unit-files "$uf" >/dev/null 2>&1 \
    && systemctl list-unit-files "$uf" 2>/dev/null | grep -q "${uf%.*}"
}

# Renders the table and fills IDX[] (display-number -> row entry) + COUNT.
declare -a IDX
COUNT=0
show_status() {
  clear
  ui_header "SERVICE STATUS & CONTROL"
  printf " ${BIWhite}%-3s %-22s %-9s %s${NC}\n" "NO" "SERVICE" "STATUS" "PORT"
  ui_rule
  local i=0 up=0 down=0 row unit label port badge
  IDX=()
  for row in "${ROWS[@]}"; do
    IFS='|' read -r unit label port <<< "$row"
    # Hide optional maintenance units that were never installed (reduce noise).
    if ! unit_installed "$unit"; then
      case "$unit" in
        quota*|limit-ip-*|autoexpire*|backup*|fixlog*) continue ;;
      esac
    fi
    ((i++))
    IDX[$i]="$row"
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      badge="${GREEN}[ ON ]${NC} "; ((up++))
    else
      badge="${RED}[ OFF ]${NC}"; ((down++))
    fi
    printf " ${BICyan}%2s${NC}  ${WHITE}%-22s${NC} %b  ${CYAN}%s${NC}\n" "$i" "$label" "$badge" "$port"
  done
  COUNT=$i
  ui_rule
  ui_status "SSH stack" "$(ssh_stack_badge)  ${CYAN}(dropbear + ssh-ws)${NC}"
  ui_rule
  echo -e " Active ${GREEN}${up}${NC}   Inactive ${RED}${down}${NC}    ${CYAN}* internal (127.0.0.1)${NC}"
  ui_foot
}

# Confirmation gate for risky actions on critical units.
confirm_critical() {
  local unit="$1" action="$2" c
  is_critical "$unit" || return 0
  echo ""
  warn "'${unit}' is critical; ${action} may cut SSH/web access."
  read -rp " Type YES to proceed: " c
  [[ "$c" == "YES" ]] && return 0
  warn "Cancelled."; sleep 1; return 1
}

# Per-service control sub-menu. Arg: row entry "unit|label|port".
manage() {
  local entry="$1" unit label port st en
  IFS='|' read -r unit label port <<< "$entry"
  while true; do
    clear
    ui_header "MANAGE SERVICE"
    st=$(systemctl is-active   "$unit" 2>/dev/null || echo unknown)
    en=$(systemctl is-enabled  "$unit" 2>/dev/null || echo unknown)
    ui_kv "Service" "$label" "$CYAN"
    ui_kv "Unit"    "$(unit_file "$unit")"
    ui_kv "Active"  "$st" "$([[ "$st" == active ]] && echo "$GREEN" || echo "$RED")"
    ui_kv "OnBoot"  "$en"
    ui_rule
    ui_opt 1 "Start"
    ui_opt 2 "Stop"
    ui_opt 3 "Restart"
    ui_opt 4 "Enable + Start (auto-start on boot)"
    ui_opt 5 "Disable + Stop"
    ui_opt 6 "View recent logs"
    ui_rule
    ui_opt 0 "Back"
    ui_foot
    read -rp " Select action : " a
    case "$a" in
      1) systemctl start   "$unit" 2>/dev/null && ok "Started ${label}."   || err "Failed to start."; sleep 1 ;;
      3) systemctl restart "$unit" 2>/dev/null && ok "Restarted ${label}." || err "Failed to restart."; sleep 1 ;;
      4) systemctl enable --now "$unit" 2>/dev/null && ok "Enabled + started ${label}." || err "Failed to enable."; sleep 1 ;;
      2) if confirm_critical "$unit" "stop"; then
           systemctl stop "$unit" 2>/dev/null && ok "Stopped ${label}." || err "Failed to stop."; sleep 1
         fi ;;
      5) if confirm_critical "$unit" "disable"; then
           systemctl disable --now "$unit" 2>/dev/null && ok "Disabled + stopped ${label}." || err "Failed to disable."; sleep 1
         fi ;;
      6) clear; ui_header "LOGS: ${label}"
         journalctl -u "$unit" -n 30 --no-pager 2>/dev/null || warn "No logs available."
         ui_back ;;
      0|x|X) return 0 ;;
      *) err "Invalid option."; sleep 1 ;;
    esac
  done
}

# --- Main loop ---
while true; do
  show_status
  echo -e " ${WHITE}Enter a service NO to manage  |  r refresh  |  0 back${NC}"
  read -rp " Select : " sel
  case "$sel" in
    r|R) continue ;;
    0|x|X) clear; exec menu-system ;;
    ''|*[!0-9]*) err "Invalid option."; sleep 1 ;;
    *)
      if (( sel >= 1 && sel <= COUNT )); then
        manage "${IDX[$sel]}"
      else
        err "Number out of range."; sleep 1
      fi ;;
  esac
done
