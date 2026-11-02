#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Complete Firewalld, SELinux (Nginx/HAProxy/SSH Permission Fix)
#              & Localhost Control-Port Isolation for EL9 & EL10
#              (Rocky 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10)
# Version: 5.6.0
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
set -u

[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

if ! declare -F info >/dev/null 2>&1; then
  NC='\033[0m'; RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'
  ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
  info() { echo -e "${BLUE}[INFO]${NC} $1"; }
  warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
  err()  { echo -e "${RED}[ERROR]${NC} $1"; }
fi

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
  err "fix-firewall must be run as root."
  exit 1
fi

QUIET="${1:-}"
log_info() { [[ "$QUIET" == "--quiet" ]] || info "$1"; }
log_ok()   { [[ "$QUIET" == "--quiet" ]] || ok "$1"; }
log_warn() { [[ "$QUIET" == "--quiet" ]] || warn "$1"; }

# ---------------------------------------------------------------------------
# 1. Firewalld Strict Allowlist + Loopback Trust
# ---------------------------------------------------------------------------
apply_firewalld() {
  log_info "Configuring firewalld ports, zones, and masquerading..."
  if ! command -v firewall-cmd >/dev/null 2>&1; then
    dnf install -y firewalld >/dev/null 2>&1 || true
  fi
  systemctl enable firewalld --now >/dev/null 2>&1 || true

  if ! systemctl is-active --quiet firewalld 2>/dev/null; then
    log_warn "firewalld is not active; skipping firewall-cmd rules."
    return 0
  fi

  firewall-cmd --set-default-zone=public >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=public --set-target=default >/dev/null 2>&1 || true

  # Trust loopback interface so HAProxy <-> Nginx <-> Xray/API/SSH-WS local
  # proxy chains never experience "Permission denied" or packet drops.
  firewall-cmd --permanent --zone=trusted --add-interface=lo >/dev/null 2>&1 || true

  # Purge insecure wide port ranges if present from legacy installs.
  firewall-cmd --permanent --zone=public --remove-port=1-65535/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --zone=public --remove-port=1-65535/udp >/dev/null 2>&1 || true
  # Ensure internal control ports are never exposed on public zone.
  for internal_port in 81/tcp 82/tcp 8081/tcp 9000/tcp 10085/tcp; do
    firewall-cmd --permanent --zone=public --remove-port="$internal_port" >/dev/null 2>&1 || true
  done

  # Public TCP ports required across SSH, Dropbear, HAProxy, Nginx, WS, CDN, OpenVPN, Squid, NoobzVPN
  local tcp_ports=(
    22 3303                 # OpenSSH Direct
    109 143                 # Dropbear Direct
    80 8080 8880            # HTTP / WebSocket / HTTPUpgrade / XHTTP
    2052 2082 2086 2095     # Cloudflare / CDN HTTP WS ports
    443 8443                # HTTPS / TLS / WSS / gRPC / Direct SSH SSL/TLS
    2053 2083 2087 2096     # Cloudflare / CDN HTTPS TLS ports
    8888                    # SSH-WS Direct HTTP
    1194                    # OpenVPN TCP
    3128 8000               # Squid Proxy (locked to VPS destination)
    8585                    # NoobzVPN Direct TCP
  )

  # Public UDP ports required across BadVPN UDPGW, OpenVPN UDP, SlowDNS, QUIC
  local udp_ports=(
    53 5300                 # SlowDNS (DNSTT)
    443 8443                # HTTP/3 / QUIC TLS
    1194 2200               # OpenVPN UDP
    7100 7200 7300          # BadVPN UDPGW
  )

  local p
  for p in "${tcp_ports[@]}"; do
    firewall-cmd --permanent --zone=public --add-port="${p}/tcp" >/dev/null 2>&1 || true
  done
  for p in "${udp_ports[@]}"; do
    firewall-cmd --permanent --zone=public --add-port="${p}/udp" >/dev/null 2>&1 || true
  done

  # Enable NAT masquerade for OpenVPN / tunnel routing
  firewall-cmd --permanent --zone=public --add-masquerade >/dev/null 2>&1 || true

  # If SlowDNS is installed, ensure UDP 53 -> 5300 port forwarding stays active
  if [[ -f /etc/slowdns/server.key ]]; then
    firewall-cmd --permanent --zone=public --add-forward-port=port=53:proto=udp:toport=5300 >/dev/null 2>&1 || true
  fi

  firewall-cmd --reload >/dev/null 2>&1 || true
  log_ok "Firewalld allowlist synchronized (TCP/UDP tunnel ports + trusted loopback)."
}

# ---------------------------------------------------------------------------
# 2. SELinux Port Types, Booleans & Contexts (Fixes Nginx Permission Denied!)
# ---------------------------------------------------------------------------
apply_selinux_fixes() {
  if ! command -v getenforce >/dev/null 2>&1; then
    log_info "SELinux utilities not present; skipping SELinux port policy."
    return 0
  fi

  local mode
  mode="$(getenforce 2>/dev/null || echo Disabled)"
  if [[ "$mode" == "Disabled" ]]; then
    log_info "SELinux is Disabled; skipping SELinux port policy."
    return 0
  fi

  log_info "Applying SELinux booleans and port policies (mode: ${mode})..."
  dnf install -y policycoreutils policycoreutils-python-utils >/dev/null 2>&1 || true

  # Critical booleans for Nginx & HAProxy reverse proxy stack on Rocky Linux 9:
  # - httpd_can_network_connect : allows Nginx to connect to 127.0.0.1:1,2,3,8888,8585,9000,10011..10033
  # - httpd_setrlimit           : allows Nginx worker_rlimit_nofile without (13: Permission denied)
  # - haproxy_connect_any       : allows HAProxy to connect to Nginx (:81, :82) and Dropbear (:109)
  local booleans=(
    httpd_can_network_connect
    httpd_can_network_connect_db
    httpd_can_network_relay
    httpd_setrlimit
    haproxy_connect_any
    nis_enabled
  )
  local b
  for b in "${booleans[@]}"; do
    setsebool -P "$b" 1 >/dev/null 2>&1 || true
  done

  # Register non-standard HTTP/2 & proxy ports into SELinux http_port_t so Nginx
  # and HAProxy can bind() without "bind() to 127.0.0.1:82 failed (13: Permission denied)"
  if command -v semanage >/dev/null 2>&1; then
    local http_ports=(
      81 82 8080 8880 8443
      2052 2053 2082 2083 2086 2087 2095 2096
      8888 8081 8585 9000
      10011 10012 10013 10021 10022 10023 10031 10032 10033
    )
    local hp
    for hp in "${http_ports[@]}"; do
      semanage port -a -t http_port_t -p tcp "$hp" >/dev/null 2>&1 || \
      semanage port -m -t http_port_t -p tcp "$hp" >/dev/null 2>&1 || true
    done
    # Register non-standard OpenSSH port 3303 into ssh_port_t for EL9/EL10 SELinux Enforcing
    semanage port -a -t ssh_port_t -p tcp 3303 >/dev/null 2>&1 || \
    semanage port -m -t ssh_port_t -p tcp 3303 >/dev/null 2>&1 || true
  fi

  # Ensure Nginx webroot & log directories have proper permissions and SELinux labels
  mkdir -p /var/www/html/risqinf/openvpn /var/log/nginx
  chmod 755 /var/www /var/www/html /var/www/html/risqinf /var/www/html/risqinf/openvpn 2>/dev/null || true
  chmod -R a+rX /var/www/html/risqinf 2>/dev/null || true

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -Rv /etc/nginx /var/log/nginx /var/lib/nginx /var/www/html /etc/haproxy >/dev/null 2>&1 || true
  fi
  if command -v chcon >/dev/null 2>&1; then
    chcon -Rt httpd_sys_content_t /var/www/html/risqinf >/dev/null 2>&1 || true
  fi

  log_ok "SELinux booleans, http_port_t bindings (81, 82, 8080, 8443...), and contexts applied."
}

# ---------------------------------------------------------------------------
# 3. Localhost Internal Daemon SSRF Protection
#    Prevents non-system SSH tunnel users (UID >= 1000) from port-forwarding
#    into localhost-only daemons (Xray API 10085, SSH-WS API 8081, API 9000).
# ---------------------------------------------------------------------------
apply_localhost_isolation() {
  if ! command -v iptables >/dev/null 2>&1; then
    return 0
  fi

  local protected_ports="81,82,8081,9000,10085,1,2,3"
  if ! iptables -C OUTPUT -o lo -p tcp -m multiport --dports "$protected_ports" -m owner --uid-owner 1000-65534 -j REJECT >/dev/null 2>&1; then
    iptables -I OUTPUT 1 -o lo -p tcp -m multiport --dports "$protected_ports" -m owner --uid-owner 1000-65534 -j REJECT >/dev/null 2>&1 || true
  fi
  if ! iptables -C OUTPUT -o lo -p tcp --dport 10011:10035 -m owner --uid-owner 1000-65534 -j REJECT >/dev/null 2>&1; then
    iptables -I OUTPUT 2 -o lo -p tcp --dport 10011:10035 -m owner --uid-owner 1000-65534 -j REJECT >/dev/null 2>&1 || true
  fi
  log_ok "Localhost internal API isolation enforced (blocks UID 1000-65534 SSRF)."
}

# ---------------------------------------------------------------------------
# 4. Validate & Reload Nginx + HAProxy
# ---------------------------------------------------------------------------
verify_proxy_services() {
  # Auto-upgrade legacy /etc/nginx/risqinf.conf if missing api_backend upstream or HTTP/2 :82 /api/ route
  if [[ -f /etc/nginx/risqinf.conf ]]; then
    if ! grep -q "upstream api_backend" /etc/nginx/risqinf.conf 2>/dev/null; then
      local tmp_ngx
      tmp_ngx=$(mktemp)
      awk '
        !added_up && /^server \{/ {
          print "upstream api_backend {"
          print "    server 127.0.0.1:9000;"
          print "    keepalive 256;"
          print "}"
          print ""
          added_up=1
        }
        { gsub(/proxy_pass http:\/\/127\.0\.0\.1:9000;/, "proxy_pass http://api_backend;\n        proxy_http_version 1.1;\n        proxy_set_header Connection \"\";\n        client_max_body_size 8m;"); print }
      ' /etc/nginx/risqinf.conf > "$tmp_ngx" && cp -f "$tmp_ngx" /etc/nginx/risqinf.conf
      rm -f "$tmp_ngx"
    fi
    if grep -q "listen 127.0.0.1:82" /etc/nginx/risqinf.conf 2>/dev/null; then
      local api_cnt
      api_cnt=$(grep -c "location /api/" /etc/nginx/risqinf.conf 2>/dev/null || echo 0)
      if (( api_cnt < 2 )); then
        local tmp_ngx2
        tmp_ngx2=$(mktemp)
        awk '
          /listen 127\.0\.0\.1:82/ { in_82=1 }
          in_82 && /^}/ {
            print ""
            print "    location /risqinf/ {"
            print "        alias /var/www/html/risqinf/;"
            print "        autoindex on;"
            print "    }"
            print ""
            print "    location /api/ {"
            print "        proxy_pass http://api_backend;"
            print "        proxy_http_version 1.1;"
            print "        proxy_set_header Connection \"\";"
            print "        proxy_set_header Host $host;"
            print "        proxy_set_header X-Real-IP $remote_addr;"
            print "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;"
            print "        proxy_connect_timeout 10s;"
            print "        proxy_read_timeout 120s;"
            print "        proxy_send_timeout 120s;"
            print "        proxy_next_upstream off;"
            print "        client_max_body_size 8m;"
            print "    }"
            in_82=0
          }
          { print }
        ' /etc/nginx/risqinf.conf > "$tmp_ngx2" && cp -f "$tmp_ngx2" /etc/nginx/risqinf.conf
        rm -f "$tmp_ngx2"
      fi
    fi
  fi

  if command -v nginx >/dev/null 2>&1 && [[ -f /etc/nginx/nginx.conf ]]; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload-or-restart nginx >/dev/null 2>&1 || true
      log_ok "Nginx configuration validated and active."
    else
      log_warn "Nginx config check reported warnings; run 'nginx -t' to inspect."
    fi
  fi

  if command -v haproxy >/dev/null 2>&1 && [[ -f /etc/haproxy/haproxy.cfg ]]; then
    if haproxy -c -f /etc/haproxy/haproxy.cfg >/dev/null 2>&1; then
      systemctl reload-or-restart haproxy >/dev/null 2>&1 || true
      log_ok "HAProxy configuration validated and active."
    fi
  fi
}

apply_firewalld
apply_selinux_fixes
apply_localhost_isolation
verify_proxy_services

if [[ "$QUIET" != "--quiet" && -t 0 && "${2:-}" == "--menu" ]]; then
  echo ""
  read -n 1 -s -r -p " Press any key to return..."
fi
exit 0
