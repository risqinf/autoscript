#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: SlowDNS (DNSTT) Server Management
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh || . "$(dirname "$0")/../lib/common.sh"

require_root

SLOWDNS_DIR="/etc/slowdns"
SLOWDNS_KEY="${SLOWDNS_DIR}/server.key"
SLOWDNS_PUB="${SLOWDNS_DIR}/server.pub"
SLOWDNS_NS="${SLOWDNS_DIR}/nameserver"
SLOWDNS_BIN="/usr/local/bin/dnstt-server"
SLOWDNS_SERVICE="/etc/systemd/system/slowdns.service"
SLOWDNS_PREBUILT_URL="https://raw.githubusercontent.com/powermx/dnstt/refs/heads/main/dns-server"

# Check if SlowDNS binary & keys are installed
slowdns_is_installed() {
  [[ -x "$SLOWDNS_BIN" && -f "$SLOWDNS_KEY" && -f "$SLOWDNS_PUB" && -f "$SLOWDNS_NS" ]]
}

# Apply firewall rules (redirect 53/udp -> 5300/udp)
slowdns_apply_firewall() {
  if command -v firewall-cmd &>/dev/null && svc_active firewalld; then
    firewall-cmd --add-port=53/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-port=5300/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --add-forward-port=port=53:proto=udp:toport=5300 --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  # Fallback / redundant direct iptables rules
  if command -v iptables &>/dev/null; then
    if ! iptables -C INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null; then
      iptables -I INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || true
    fi
    if ! iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null; then
      iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || true
    fi
  fi
}

# Remove firewall rules
slowdns_remove_firewall() {
  if command -v firewall-cmd &>/dev/null && svc_active firewalld; then
    firewall-cmd --remove-forward-port=port=53:proto=udp:toport=5300 --permanent >/dev/null 2>&1 || true
    firewall-cmd --remove-port=5300/udp --permanent >/dev/null 2>&1 || true
    firewall-cmd --reload >/dev/null 2>&1 || true
  fi

  if command -v iptables &>/dev/null; then
    while iptables -t nat -C PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null; do
      iptables -t nat -D PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300 2>/dev/null || break
    done
    while iptables -C INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null; do
      iptables -D INPUT -p udp --dport 5300 -j ACCEPT 2>/dev/null || break
    done
  fi
}

# Generate keypair
slowdns_gen_keys() {
  mkdir -p "$SLOWDNS_DIR"; chmod 700 "$SLOWDNS_DIR"
  rm -f "$SLOWDNS_KEY" "$SLOWDNS_PUB"

  "$SLOWDNS_BIN" -gen-key -privkey-file "$SLOWDNS_KEY" -pubkey-file "$SLOWDNS_PUB" >/dev/null 2>&1
  if [[ ! -s "$SLOWDNS_KEY" || ! -s "$SLOWDNS_PUB" ]]; then
    err "Failed to generate SlowDNS keys."
    return 1
  fi
  chmod 600 "$SLOWDNS_KEY"
  chmod 644 "$SLOWDNS_PUB"
  ok "SlowDNS keypair generated successfully."
}

# Create systemd service unit
slowdns_setup_service() {
  local ns
  ns=$(cat "$SLOWDNS_NS" 2>/dev/null | tr -d '\r\n')
  if [[ -z "$ns" ]]; then
    err "Nameserver not configured."
    return 1
  fi

  cat > "$SLOWDNS_SERVICE" <<EOF
[Unit]
Description=SlowDNS (DNSTT) Tunnel Server
After=network.target
Documentation=https://github.com/risqinf/autoscript

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=${SLOWDNS_BIN} -udp :5300 -privkey-file ${SLOWDNS_KEY} ${ns} 127.0.0.1:109
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable slowdns >/dev/null 2>&1
}

# Install SlowDNS core
slowdns_install() {
  ui_header "SLOWDNS (DNSTT) INSTALLATION"
  info "Preparing SlowDNS (DNSTT) Server..."

  mkdir -p "$SLOWDNS_DIR"
  chmod 700 "$SLOWDNS_DIR"

  # 1. Obtain binary
  if [[ ! -x "$SLOWDNS_BIN" ]]; then
    local installed=0
    # Try downloading prebuilt binary
    info "Downloading prebuilt dnstt-server binary..."
    if curl -sSL --connect-timeout 10 -o "$SLOWDNS_BIN" "$SLOWDNS_PREBUILT_URL" 2>/dev/null && [[ -s "$SLOWDNS_BIN" ]]; then
      chmod +x "$SLOWDNS_BIN"
      if "$SLOWDNS_BIN" -help >/dev/null 2>&1 || "$SLOWDNS_BIN" -version >/dev/null 2>&1; then
        installed=1
        ok "Prebuilt dnstt-server binary installed."
      else
        rm -f "$SLOWDNS_BIN"
      fi
    fi

    # Fallback to Go build if prebuilt binary fails or machine architecture differs
    if (( installed == 0 )); then
      if command -v go &>/dev/null; then
        info "Compiling dnstt-server from source with Go..."
        local build_tmp
        build_tmp=$(mktemp -d)
        if git clone --depth 1 https://www.bamsoftware.com/git/dnstt.git "$build_tmp/dnstt" >/dev/null 2>&1; then
          ( cd "$build_tmp/dnstt/dnstt-server" && CGO_ENABLED=0 go build -ldflags="-s -w" -o "$SLOWDNS_BIN" )
          chmod +x "$SLOWDNS_BIN"
          [[ -x "$SLOWDNS_BIN" ]] && installed=1
        fi
        rm -rf "$build_tmp"
      fi
    fi

    if [[ ! -x "$SLOWDNS_BIN" ]]; then
      err "Failed to install dnstt-server binary. Please check internet access or install Go."
      return 1
    fi
  fi

  # Symlink to /usr/sbin/dns-server for backward compatibility with legacy scripts
  ln -sf "$SLOWDNS_BIN" /usr/sbin/dns-server 2>/dev/null || true

  # 2. Key generation
  if [[ ! -s "$SLOWDNS_KEY" || ! -s "$SLOWDNS_PUB" ]]; then
    slowdns_gen_keys || return 1
  fi

  # 3. Nameserver prompt
  local domain; domain=$(get_domain)
  local default_ns="ns.${domain}"
  local ns_input=""

  echo ""
  echo -e " ${WHITE}Enter your Nameserver (NS) Subdomain.${NC}"
  echo -e " ${YELLOW}Note: Make sure NS record points to an A record of this VPS IP.${NC}"
  read -rp " Nameserver [Default: ${default_ns}]: " ns_input
  [[ -z "$ns_input" ]] && ns_input="$default_ns"

  # Clean input
  ns_input=$(echo "$ns_input" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  if [[ ! "$ns_input" =~ ^[a-z0-9.-]+$ ]]; then
    err "Invalid domain name format."
    return 1
  fi

  echo "$ns_input" > "$SLOWDNS_NS"
  ok "Nameserver set to: ${ns_input}"

  # 4. Service setup & startup
  slowdns_setup_service || return 1
  slowdns_apply_firewall
  systemctl restart slowdns

  if svc_active slowdns; then
    ok "SlowDNS (DNSTT) Server installed and started successfully!"
  else
    warn "SlowDNS service failed to start. Check: journalctl -u slowdns"
  fi
}

# Uninstall SlowDNS
slowdns_uninstall() {
  ui_header "UNINSTALL SLOWDNS"
  read -rp " Are you sure you want to remove SlowDNS? [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    warn "Cancelled."
    return 0
  fi

  info "Stopping and removing SlowDNS service..."
  systemctl stop slowdns >/dev/null 2>&1
  systemctl disable slowdns >/dev/null 2>&1
  rm -f "$SLOWDNS_SERVICE"
  systemctl daemon-reload

  slowdns_remove_firewall

  rm -rf "$SLOWDNS_DIR"
  rm -f "$SLOWDNS_BIN" /usr/sbin/dns-server

  ok "SlowDNS (DNSTT) uninstalled completely."
}

# Start service
slowdns_start() {
  if ! slowdns_is_installed; then
    warn "SlowDNS is not installed yet. Please install it first."
    return 1
  fi
  slowdns_apply_firewall
  systemctl start slowdns
  if svc_active slowdns; then
    ok "SlowDNS service started."
  else
    err "Failed to start SlowDNS. Check journalctl -u slowdns."
  fi
}

# Stop service
slowdns_stop() {
  systemctl stop slowdns
  slowdns_remove_firewall
  ok "SlowDNS service stopped."
}

# Restart service
slowdns_restart() {
  if ! slowdns_is_installed; then
    warn "SlowDNS is not installed yet."
    return 1
  fi
  slowdns_apply_firewall
  systemctl restart slowdns
  if svc_active slowdns; then
    ok "SlowDNS service restarted."
  else
    err "Failed to restart SlowDNS."
  fi
}

# Change Nameserver
slowdns_change_ns() {
  if [[ ! -f "$SLOWDNS_NS" ]]; then
    warn "SlowDNS is not installed yet."
    return 1
  fi

  local current_ns; current_ns=$(cat "$SLOWDNS_NS" 2>/dev/null)
  local domain; domain=$(get_domain)
  local default_ns="ns.${domain}"

  ui_header "CHANGE SLOWDNS NAMESERVER"
  echo -e " Current NS : ${CYAN}${current_ns}${NC}"
  echo ""
  read -rp " Enter New Nameserver [Default: ${default_ns}]: " new_ns
  [[ -z "$new_ns" ]] && new_ns="$default_ns"
  new_ns=$(echo "$new_ns" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')

  if [[ ! "$new_ns" =~ ^[a-z0-9.-]+$ ]]; then
    err "Invalid domain name format."
    return 1
  fi

  echo "$new_ns" > "$SLOWDNS_NS"
  slowdns_setup_service
  systemctl restart slowdns
  ok "Nameserver changed to ${new_ns} and service reloaded."
}

# Regenerate keypair
slowdns_regen_key() {
  if [[ ! -x "$SLOWDNS_BIN" ]]; then
    warn "SlowDNS is not installed yet."
    return 1
  fi

  ui_header "REGENERATE SLOWDNS KEYPAIR"
  read -rp " Are you sure you want to regenerate keypair? (Clients will need new pubkey) [y/N]: " confirm
  if [[ ! "$confirm" =~ ^[yY]$ ]]; then
    warn "Cancelled."
    return 0
  fi

  slowdns_gen_keys || return 1
  slowdns_setup_service
  systemctl restart slowdns
  ok "New keypair active."
  echo -e " Public Key : ${GREEN}$(cat "$SLOWDNS_PUB" 2>/dev/null)${NC}"
}

# Display detailed info
slowdns_info() {
  local status_badge; status_badge=$(svc_badge slowdns)
  local ns; ns=$(cat "$SLOWDNS_NS" 2>/dev/null || echo "(not set)")
  local pub; pub=$(cat "$SLOWDNS_PUB" 2>/dev/null || echo "(not generated)")

  ui_header "SLOWDNS (DNSTT) INFORMATION"
  ui_status "Service " "$status_badge"
  ui_kv "Port" "53 / 5300 UDP"
  ui_kv "Forward" "Dropbear SSH (127.0.0.1:109)"
  ui_kv "Nameserver" "${ns}"
  ui_kv "Public Key" "${pub}"
  ui_rule
}

# CLI dispatcher
case "${1:-}" in
  install)   slowdns_install ;;
  uninstall) slowdns_uninstall ;;
  start)     slowdns_start ;;
  stop)      slowdns_stop ;;
  restart)   slowdns_restart ;;
  change-ns) slowdns_change_ns ;;
  regen-key) slowdns_regen_key ;;
  info)      slowdns_info ;;
  status)    svc_badge slowdns ;;
  *)
    if command -v menu-slowdns &>/dev/null; then
      menu-slowdns
    elif [[ -f /usr/local/sbin/menu/menu-slowdns.sh ]]; then
      /usr/local/sbin/menu/menu-slowdns.sh
    elif [[ -f "$(dirname "$0")/../menu/menu-slowdns.sh" ]]; then
      "$(dirname "$0")/../menu/menu-slowdns.sh"
    elif [[ -f "$(dirname "$0")/menu-slowdns.sh" ]]; then
      "$(dirname "$0")/menu-slowdns.sh"
    else
      slowdns_info
    fi
    ;;
esac
