#!/usr/bin/env bash
# ========================================================
# Project: RDNS Client Manager (mTLS Yamux Stealth Tunnel)
# Author / Credit: github: @risqinf
# License: Apache License 2.0
# Description: Pairing token decoder, profile manager, dynamic
#              rules engine with collision avoidance & presets
# ========================================================
set -euo pipefail

# --- Source Autoscript UI & Colors ---
if [[ -f /usr/local/sbin/lib/common.sh ]]; then
  . /usr/local/sbin/lib/common.sh
elif [[ -f "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh" ]]; then
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
else
  NC='\033[0m'
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  WHITE='\033[1;37m'
  ORANGE='\033[38;5;208m'
  PINK='\033[38;5;205m'
  PILL_TITLE='\033[30;107m'
  ui_width() { echo 56; }
  ui_rep() { local ch="$1" n="$2" out=""; while (( n > 0 )); do out+="$ch"; ((n--)); done; printf '%s' "$out"; }
  ui_rule() { echo -e "${CYAN}$(ui_rep '═' 56)${NC}"; }
  ui_edge() { echo -e "${ORANGE}$(ui_rep '═' 56)${NC}"; }
  ui_foot() { ui_edge; }
  ui_kv() { printf " ${WHITE}%-14s${NC} ${CYAN}:${NC} %b\n" "$1" "$2"; }
  ok()   { echo -e " ${GREEN}[OK]${NC} $1"; }
  info() { echo -e " ${BLUE}[INFO]${NC} $1"; }
  warn() { echo -e " ${YELLOW}[WARN]${NC} $1"; }
  err()  { echo -e " ${RED}[ERROR]${NC} $1"; }
fi

RDNS_DIR="${RDNS_DIR:-/etc/rdns}"
CERTS_DIR="${RDNS_DIR}/certs"
CONFIG_FILE="${RDNS_DIR}/client.yaml"
RULES_FILE="${RDNS_DIR}/rules.json"

if [[ -d "/usr/local/sbin/rdns/presets" ]]; then
  PRESETS_DIR="/usr/local/sbin/rdns/presets"
elif [[ -d "/etc/rdns/presets" ]]; then
  PRESETS_DIR="/etc/rdns/presets"
elif [[ -d "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/presets" ]]; then
  PRESETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/presets"
else
  PRESETS_DIR="/usr/local/sbin/presets"
fi

# Ensure directories exist
mkdir -p "$CERTS_DIR" 2>/dev/null || true

# Helper for JSON operations via jq or python3
json_tool() {
  if command -v jq &>/dev/null; then
    echo "jq"
  elif command -v python3 &>/dev/null; then
    echo "python3"
  else
    echo "none"
  fi
}

# Cross-platform service helpers (systemd & Alpine OpenRC)
is_rdns_active() {
  if command -v systemctl &>/dev/null; then
    systemctl is-active rdns-client &>/dev/null
  elif command -v rc-service &>/dev/null; then
    rc-service rdns-client status &>/dev/null
  else
    pgrep -x rdns-client &>/dev/null
  fi
}

ensure_rdns_installed() {
  # 1. Pastikan direktori kerja dan file log selalu siap
  mkdir -p "$CERTS_DIR" "$PRESETS_DIR" "${RDNS_DIR}/presets" 2>/dev/null || true
  mkdir -p /var/log 2>/dev/null || true
  if [[ ! -f "/var/log/rdns-client.log" ]]; then
    touch "/var/log/rdns-client.log" 2>/dev/null || true
    chmod 644 "/var/log/rdns-client.log" 2>/dev/null || true
  fi

  # Auto-migrate legacy port 5353 ke 14053 jika konfigurasi client lama ditemukan
  if [[ -f "$CONFIG_FILE" ]] && grep -q "0.0.0.0:5353" "$CONFIG_FILE" 2>/dev/null; then
    info "Migrasi otomatis: memindahkan DNS interceptor dari port 5353 ke 14053..."
    sed -i 's/0.0.0.0:5353/0.0.0.0:14053/g' "$CONFIG_FILE" 2>/dev/null || true
  fi

  # 2. Pastikan dependensi PyYAML tersedia jika Python digunakan
  if command -v python3 &>/dev/null; then
    if ! python3 -c "import yaml" 2>/dev/null; then
      info "Memverifikasi modul python3-pyyaml untuk integrasi YAML..."
      if command -v dnf &>/dev/null; then
        dnf install -y python3-pyyaml >/dev/null 2>&1 || true
      elif command -v apt-get &>/dev/null; then
        apt-get install -y python3-yaml >/dev/null 2>&1 || true
      elif command -v apk &>/dev/null; then
        apk add --no-cache py3-yaml >/dev/null 2>&1 || true
      elif command -v pip3 &>/dev/null; then
        pip3 install pyyaml >/dev/null 2>&1 || true
      fi
    fi
  fi

  # 3. Pastikan binary rdns-client terpasang di /usr/local/bin dan up-to-date (v0.2.1)
  local need_binary_install=false
  if [[ ! -x /usr/local/bin/rdns-client ]]; then
    need_binary_install=true
  elif ! /usr/local/bin/rdns-client -version 2>/dev/null | grep -q "v0.2.1"; then
    info "Versi rdns-client terpasang ($(/usr/local/bin/rdns-client -version 2>/dev/null || echo 'lama')) perlu diupdate ke v0.2.1..."
    need_binary_install=true
  fi

  if [[ "$need_binary_install" == "true" ]]; then
    info "Binary /usr/local/bin/rdns-client sedang dipasang/diperbarui..."
    local arch
    case "$(uname -m)" in
      x86_64|amd64) arch="amd64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) arch="" ;;
    esac

    local installed=false
    local candidate_paths=(
      "/home/risqinf/Project-Real/rdns/dist/rdns-client-linux-${arch}"
      "/home/risqinf/Project-Real/rdns/bin/rdns-client-linux"
      "/usr/local/share/autoscript/bin/rdns-client-linux-${arch}"
      "/usr/local/share/autoscript/bin/rdns-client"
    )
    for c in "${candidate_paths[@]}"; do
      if [[ -x "$c" ]]; then
        info "Menginstal rdns-client dari sumber lokal: $c"
        if [[ -w /usr/local/bin ]] || [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
          cp -f "$c" /usr/local/bin/rdns-client 2>/dev/null || sudo cp -f "$c" /usr/local/bin/rdns-client 2>/dev/null || true
          chmod 755 /usr/local/bin/rdns-client 2>/dev/null || sudo chmod 755 /usr/local/bin/rdns-client 2>/dev/null || true
        fi
        installed=true
        break
      fi
    done

    if [[ "$installed" != "true" && -n "$arch" ]]; then
      info "Mengunduh binary resmi rdns-client (v0.2.1)..."
      if [[ -w /usr/local/bin ]] || [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        curl -sSL --connect-timeout 10 --max-time 30 -o /usr/local/bin/rdns-client \
          "https://github.com/risqinf/rdns/releases/download/v0.2.1/rdns-client-linux-${arch}" 2>/dev/null || true
        chmod 755 /usr/local/bin/rdns-client 2>/dev/null || sudo chmod 755 /usr/local/bin/rdns-client 2>/dev/null || true
      fi
    fi

    if [[ ! -x /usr/local/bin/rdns-client ]]; then
      warn "Binary /usr/local/bin/rdns-client belum terpasang (memerlukan izin root)."
    else
      ok "Binary rdns-client berhasil dipasang di /usr/local/bin/rdns-client ($(/usr/local/bin/rdns-client -version 2>/dev/null || echo 'v0.2.1'))"
    fi
  fi

  # 4. Pastikan unit systemd rdns-client.service terpasang & aktif
  if command -v systemctl &>/dev/null; then
    local svc_file="/etc/systemd/system/rdns-client.service"
    if [[ ! -f "$svc_file" ]] || ! grep -q "ReadWritePaths" "$svc_file" 2>/dev/null || ! grep -q "ExecStartPre" "$svc_file" 2>/dev/null; then
      if [[ -w /etc/systemd/system ]] || [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
        info "Memasang dan memperbarui service systemd: $svc_file..."
        cat > "$svc_file" <<'EOF_RDNS_UNIT'
[Unit]
Description=rdns-client (decision node: split DNS + SNI traffic router)
Documentation=https://github.com/risqinf/rdns
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStartPre=-/bin/sh -c 'mkdir -p /var/log /etc/rdns/certs && touch /var/log/rdns-client.log && chmod 644 /var/log/rdns-client.log 2>/dev/null || true'
ExecStart=/usr/local/bin/rdns-client -config /etc/rdns/client.yaml
ExecReload=/bin/kill -HUP $MAINPID
SyslogIdentifier=rdns-client
ProtectSystem=strict
ReadWritePaths=/var/log /var/log/rdns-client.log /etc/rdns
ProtectHome=true
PrivateTmp=true
LimitNOFILE=65536
Restart=always
RestartSec=3
TimeoutStopSec=15
ExecStopPost=-/usr/sbin/nft delete table ip rdns
ExecStopPost=-/usr/sbin/nft delete table ip6 rdns

[Install]
WantedBy=multi-user.target
EOF_RDNS_UNIT
        chmod 644 "$svc_file" 2>/dev/null || true
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl enable rdns-client >/dev/null 2>&1 || true
        ok "Service rdns-client terkonfigurasi dan diaktifkan di systemd."
      fi
    fi
  fi
  return 0
}

print_health_summary() {
  local pid=""
  if command -v pgrep &>/dev/null; then
    pid=$(pgrep -f "rdns-client.*-config" | head -1 || echo "")
    [[ -z "$pid" ]] && pid=$(pgrep -x rdns-client | head -1 || echo "")
  fi

  echo ""
  ui_label "STATUS DETEKSI SISTEM & RUNTIME RDNS"

  if [[ -n "$pid" ]]; then
    echo -e "   ${GREEN}[✓]${NC} ${WHITE}Service Daemon    :${NC} ${GREEN}ACTIVE${NC} ${WHITE}(PID: ${pid})${NC}"
  else
    echo -e "   ${GREEN}[✓]${NC} ${WHITE}Service Daemon    :${NC} ${GREEN}ACTIVE${NC}"
  fi

  # Deteksi interceptor ports
  local dns_target_port="14053"
  if [[ -f "$CONFIG_FILE" ]]; then
    local p_find
    p_find=$(grep -E '^\s*dns:\s*"?0\.0\.0\.0:[0-9]+' "$CONFIG_FILE" 2>/dev/null | awk -F: '{print $NF}' | tr -d ' "' || echo "")
    [[ -n "$p_find" ]] && dns_target_port="$p_find"
  fi

  if command -v ss &>/dev/null; then
    if ss -uln 2>/dev/null | grep -q ":${dns_target_port} "; then
      echo -e "   ${GREEN}[✓]${NC} ${WHITE}DNS Interceptor   :${NC} ${CYAN}LISTENING (:${dns_target_port} UDP)${NC}"
    else
      echo -e "   ${YELLOW}[!]${NC} ${WHITE}DNS Interceptor   :${NC} ${YELLOW}Binding in progress (:${dns_target_port})${NC}"
    fi

    if ss -tln 2>/dev/null | grep -q ':14300 '; then
      echo -e "   ${GREEN}[✓]${NC} ${WHITE}SNI Interceptor   :${NC} ${CYAN}LISTENING (:14300 TCP)${NC}"
    else
      echo -e "   ${YELLOW}[!]${NC} ${WHITE}SNI Interceptor   :${NC} ${YELLOW}Binding in progress (:14300)${NC}"
    fi

    if ss -uln 2>/dev/null | grep -q ':14400 '; then
      echo -e "   ${GREEN}[✓]${NC} ${WHITE}QUIC Interceptor  :${NC} ${CYAN}LISTENING (:14400 UDP)${NC}"
    else
      echo -e "   ${YELLOW}[!]${NC} ${WHITE}QUIC Interceptor  :${NC} ${YELLOW}Binding in progress (:14400)${NC}"
    fi
  fi

  # Deteksi nftables redirect
  if command -v nft &>/dev/null; then
    if nft list table ip rdns &>/dev/null; then
      echo -e "   ${GREEN}[✓]${NC} ${WHITE}Netfilter TProxy  :${NC} ${GREEN}ACTIVE (table ip rdns)${NC}"
    else
      echo -e "   ${YELLOW}[!]${NC} ${WHITE}Netfilter TProxy  :${NC} ${YELLOW}Awaiting listener sync${NC}"
    fi
  fi

  # Deteksi file log
  if [[ -f /var/log/rdns-client.log ]]; then
    echo -e "   ${GREEN}[✓]${NC} ${WHITE}Logging Stream    :${NC} ${CYAN}/var/log/rdns-client.log (Siap)${NC}"
  fi
  echo ""
}

start_and_verify_rdns() {
  info "Memulai dan memverifikasi service rdns-client..."

  # Pastikan file log dibuat sebelum service start
  mkdir -p /var/log 2>/dev/null || true
  touch /var/log/rdns-client.log 2>/dev/null || true
  chmod 644 /var/log/rdns-client.log 2>/dev/null || true

  if command -v systemctl &>/dev/null; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart rdns-client 2>/dev/null || true
  elif command -v rc-service &>/dev/null; then
    rc-service rdns-client restart >/dev/null 2>&1 || true
  elif pgrep -x rdns-client &>/dev/null; then
    pkill -x rdns-client || true
    sleep 1
    nohup /usr/local/bin/rdns-client -config "$CONFIG_FILE" >>/var/log/rdns-client.log 2>&1 &
  fi

  # Deteksi aktif dengan polling hingga 6 detik
  local active=false
  for (( i=1; i<=6; i++ )); do
    sleep 1
    if is_rdns_active; then
      active=true
      break
    fi
  done

  if [[ "$active" == "true" ]]; then
    ok "Service rdns-client BERHASIL AKTIF dan BERJALAN NORMAL!"
    print_health_summary
    return 0
  else
    err "Service rdns-client GAGAL AKTIF!"
    echo ""
    echo -e " ${YELLOW}--- Diagnostik Kegagalan (Log Terakhir) ---${NC}"
    if command -v journalctl &>/dev/null; then
      journalctl -u rdns-client -n 15 --no-pager 2>/dev/null || true
    fi
    if [[ -s /var/log/rdns-client.log ]]; then
      echo -e " ${CYAN}Log /var/log/rdns-client.log:${NC}"
      tail -n 12 /var/log/rdns-client.log 2>/dev/null || true
    fi
    echo -e " ${YELLOW}-------------------------------------------${NC}"
    return 1
  fi
}

reload_rdns() {
  if command -v systemctl &>/dev/null && systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || systemctl restart rdns-client 2>/dev/null || true
  elif command -v rc-service &>/dev/null && rc-service rdns-client status &>/dev/null; then
    rc-service rdns-client reload 2>/dev/null || rc-service rdns-client restart 2>/dev/null || true
  else
    pkill -HUP -x rdns-client 2>/dev/null || true
  fi
  sleep 1
  if is_rdns_active; then
    ok "Rules dan konfigurasi rdns-client berhasil direload!"
  else
    warn "rdns-client tidak aktif setelah reload. Memulai ulang..."
    start_and_verify_rdns
  fi
}

ensure_base_config() {
  local profile_name="$1"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "Generating base configuration: $CONFIG_FILE..."
    cat >"$CONFIG_FILE" <<EOF
listen:
  dns:  "0.0.0.0:14053"
  sni:  "0.0.0.0:14300"
  quic: "0.0.0.0:14400"

rules: "${RULES_FILE}"

cdn_direct: true

tls:
  ca_file:   "${CERTS_DIR}/${profile_name}-ca.crt"
  cert_file: "${CERTS_DIR}/${profile_name}.crt"
  key_file:  "${CERTS_DIR}/${profile_name}.key"

dns:
  default_upstream: "8.8.8.8:53"
  timeout: 3s

reconnect:
  min: 1s
  max: 30s

logging:
  level: info
  file: "/var/log/rdns-client.log"

tunnel_mark: 0x200

profiles: []
EOF
    chmod 644 "$CONFIG_FILE"
  else
    # Auto-migrate conflict port 5353 (used by dnsmasq / mDNS) to 14053
    if grep -q "0.0.0.0:5353" "$CONFIG_FILE" 2>/dev/null; then
      sed -i 's/0.0.0.0:5353/0.0.0.0:14053/g' "$CONFIG_FILE" 2>/dev/null || true
    fi
  fi

  if [[ ! -f "$RULES_FILE" ]]; then
    echo "{}" >"$RULES_FILE"
    chmod 644 "$RULES_FILE"
  fi

  # Pastikan file log dibuat dengan izin yang tepat
  mkdir -p /var/log 2>/dev/null || true
  touch /var/log/rdns-client.log 2>/dev/null || true
  chmod 644 /var/log/rdns-client.log 2>/dev/null || true
}

# --- Command: pair ---
cmd_pair() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    err "Pairing token is required."
    echo "Usage: rdns-manager pair <rdns://...>"
    exit 1
  fi

  # Pastikan seluruh prasyarat runtime RDNS (binary, service, log) telah terpasang
  ensure_rdns_installed

  if [[ "$token" != rdns://* ]]; then
    err "Invalid token format. Token must begin with 'rdns://'."
    exit 1
  fi

  local b64_payload="${token#rdns://}"
  local json_payload
  json_payload=$(echo "$b64_payload" | base64 -d 2>/dev/null || echo "")

  if [[ -z "$json_payload" ]]; then
    err "Failed to base64-decode pairing token."
    exit 1
  fi

  # Extract fields using python3 or jq
  local tool; tool=$(json_tool)
  local profile_name server_addr server_name dns_upstream client_ip expires_at
  if [[ "$tool" == "jq" ]]; then
    profile_name=$(echo "$json_payload" | jq -r '.profile_name // empty')
    server_addr=$(echo "$json_payload" | jq -r '.server_addr // empty')
    server_name=$(echo "$json_payload" | jq -r '.server_name // empty')
    dns_upstream=$(echo "$json_payload" | jq -r '.dns_upstream // empty')
    client_ip=$(echo "$json_payload" | jq -r '.client_ip // empty')
    expires_at=$(echo "$json_payload" | jq -r '.expires_at // 0')
  elif [[ "$tool" == "python3" ]]; then
    profile_name=$(python3 -c "import sys, json; p=json.loads(sys.argv[1]); print(p.get('profile_name',''))" "$json_payload")
    server_addr=$(python3 -c "import sys, json; p=json.loads(sys.argv[1]); print(p.get('server_addr',''))" "$json_payload")
    server_name=$(python3 -c "import sys, json; p=json.loads(sys.argv[1]); print(p.get('server_name',''))" "$json_payload")
    dns_upstream=$(python3 -c "import sys, json; p=json.loads(sys.argv[1]); print(p.get('dns_upstream',''))" "$json_payload")
    client_ip=$(python3 -c "import sys, json; p=json.loads(sys.argv[1]); print(p.get('client_ip',''))" "$json_payload")
    expires_at=$(python3 -c "import sys, json; p=json.loads(sys.argv[1]); print(p.get('expires_at',0))" "$json_payload")
  else
    err "Neither 'jq' nor 'python3' is installed on this system."
    exit 1
  fi

  if [[ -z "$profile_name" || -z "$server_addr" ]]; then
    err "Corrupted pairing token payload (missing profile_name or server_addr)."
    exit 1
  fi

  ensure_base_config "$profile_name"

  info "Installing certificates for profile: ${profile_name}..."
  # Extract CA cert, client cert, and client key
  if [[ "$tool" == "jq" ]]; then
    echo "$json_payload" | jq -r '.ca_cert' >"${CERTS_DIR}/${profile_name}-ca.crt"
    echo "$json_payload" | jq -r '.client_cert' >"${CERTS_DIR}/${profile_name}.crt"
    echo "$json_payload" | jq -r '.client_key' >"${CERTS_DIR}/${profile_name}.key"
  else
    python3 -c "import sys, json; p=json.loads(sys.argv[1]); open('${CERTS_DIR}/${profile_name}-ca.crt','w').write(p['ca_cert']); open('${CERTS_DIR}/${profile_name}.crt','w').write(p['client_cert']); open('${CERTS_DIR}/${profile_name}.key','w').write(p['client_key'])" "$json_payload"
  fi
  chmod 600 "${CERTS_DIR}/${profile_name}.key"
  chmod 644 "${CERTS_DIR}/${profile_name}.crt" "${CERTS_DIR}/${profile_name}-ca.crt"

  # Update client.yaml profiles list using python3 or sed
  info "Updating profile in ${CONFIG_FILE}..."
  python3 - <<EOF
import yaml, os

cfg_path = "${CONFIG_FILE}"
with open(cfg_path, 'r') as f:
    cfg = yaml.safe_load(f) or {}

profiles = cfg.get('profiles', [])
new_prof = {
    'name': "${profile_name}",
    'server': "${server_addr}",
    'server_name': "${server_name}",
    'dns': "${dns_upstream}" if "${dns_upstream}" else "127.0.0.1:53"
}

# Replace if exists, else append
found = False
for i, p in enumerate(profiles):
    if p.get('name') == "${profile_name}":
        profiles[i] = new_prof
        found = True
        break
if not found:
    profiles.append(new_prof)

cfg['profiles'] = profiles

# Update tls block if default or empty
tls = cfg.get('tls', {})
tls['ca_file'] = "${CERTS_DIR}/${profile_name}-ca.crt"
tls['cert_file'] = "${CERTS_DIR}/${profile_name}.crt"
tls['key_file'] = "${CERTS_DIR}/${profile_name}.key"
cfg['tls'] = tls

with open(cfg_path, 'w') as f:
    yaml.dump(cfg, f, default_flow_style=False)
EOF

  # Ensure profile exists in rules.json
  python3 - <<EOF
import json
rules_path = "${RULES_FILE}"
try:
    with open(rules_path, 'r') as f:
        rules = json.load(f)
except Exception:
    rules = {}

if "${profile_name}" not in rules:
    rules["${profile_name}"] = []

with open(rules_path, 'w') as f:
    json.dump(rules, f, indent=2)
EOF

  ok "Profile '${profile_name}' paired successfully!"
  info "Menerapkan konfigurasi dan memverifikasi kesiapan service rdns-client..."
  start_and_verify_rdns || true
  ui_rule
  ui_kv "Profile Name" "$profile_name" "$GREEN"
  ui_kv "Server Host"  "$server_addr" "$CYAN"
  ui_kv "Server Name"  "$server_name" "$CYAN"
  ui_kv "DNS Upstream" "${dns_upstream:-127.0.0.1:53}" "$WHITE"
  ui_kv "Credit"       "github: @risqinf" "$PINK"
  ui_foot
}

# --- Command: add-rule ---
cmd_add_rule() {
  local profile="$1"
  local raw_domains="$2"

  if [[ ! -f "$RULES_FILE" ]]; then
    echo "{}" >"$RULES_FILE"
  fi

  python3 - <<EOF
import json, sys

rules_path = "${RULES_FILE}"
with open(rules_path, 'r') as f:
    rules = json.load(f)

target_prof = "${profile}"
if target_prof not in rules:
    rules[target_prof] = []

raw = "${raw_domains}"
new_domains = [d.strip().lower() for d in raw.split(',') if d.strip()]

# Collision avoidance: Remove duplicates from other profiles first!
for d in new_domains:
    for p, dlist in rules.items():
        if p != target_prof and d in dlist:
            dlist.remove(d)

for d in new_domains:
    if d not in rules[target_prof]:
        rules[target_prof].append(d)

with open(rules_path, 'w') as f:
    json.dump(rules, f, indent=2)

print(f"Added {len(new_domains)} domain(s) to profile '{target_prof}'.")
EOF

  if is_rdns_active; then
    reload_rdns
    ok "Rules reloaded on running rdns-client."
  fi
}

# --- Command: remove-rule ---
cmd_remove_rule() {
  local profile="$1"
  local raw_domains="$2"

  if [[ ! -f "$RULES_FILE" ]]; then
    return 0
  fi

  python3 - <<EOF
import json

rules_path = "${RULES_FILE}"
with open(rules_path, 'r') as f:
    rules = json.load(f)

target_prof = "${profile}"
if target_prof not in rules:
    print(f"Profile '{target_prof}' not found in rules.")
    sys.exit(0)

raw = "${raw_domains}"
del_domains = [d.strip().lower() for d in raw.split(',') if d.strip()]

for d in del_domains:
    if d in rules[target_prof]:
        rules[target_prof].remove(d)

with open(rules_path, 'w') as f:
    json.dump(rules, f, indent=2)

print(f"Removed domain(s) from profile '{target_prof}'.")
EOF

  if is_rdns_active; then
    reload_rdns
    ok "Rules reloaded."
  fi
}

# --- Command: load-preset ---
cmd_load_preset() {
  local profile="$1"
  local preset="$2"
  local preset_file="${PRESETS_DIR}/${preset}.json"

  if [[ ! -f "$preset_file" ]]; then
    err "Preset '${preset}' not found in ${PRESETS_DIR}."
    exit 1
  fi

  python3 - <<EOF
import json

rules_path = "${RULES_FILE}"
preset_path = "${preset_file}"
preset_name = "${preset}"
target_prof = "${profile}"

with open(preset_path, 'r') as f:
    preset_domains = json.load(f)

try:
    with open(rules_path, 'r') as f:
        rules = json.load(f)
except Exception:
    rules = {}

if target_prof not in rules:
    rules[target_prof] = []

# Collision avoidance across profiles
for d in preset_domains:
    d = d.strip().lower()
    for p, dlist in rules.items():
        if p != target_prof and d in dlist:
            dlist.remove(d)
    if d not in rules[target_prof]:
        rules[target_prof].append(d)

with open(rules_path, 'w') as f:
    json.dump(rules, f, indent=2)

print(f"Preset '{preset_name}' ({len(preset_domains)} domains) applied to profile '{target_prof}'.")
EOF

  if is_rdns_active; then
    reload_rdns
    ok "Rules reloaded on running rdns-client."
  fi
}

# --- Command: remove-preset ---
cmd_remove_preset() {
  local profile="$1"
  local preset="$2"
  local preset_file="${PRESETS_DIR}/${preset}.json"

  if [[ ! -f "$preset_file" ]]; then
    err "Preset '${preset}' not found."
    exit 1
  fi

  python3 - <<EOF
import json

rules_path = "${RULES_FILE}"
preset_path = "${preset_file}"
preset_name = "${preset}"
target_prof = "${profile}"

with open(preset_path, 'r') as f:
    preset_domains = json.load(f)

try:
    with open(rules_path, 'r') as f:
        rules = json.load(f)
except Exception:
    rules = {}

if target_prof in rules:
    for d in preset_domains:
        d = d.strip().lower()
        if d in rules[target_prof]:
            rules[target_prof].remove(d)

with open(rules_path, 'w') as f:
    json.dump(rules, f, indent=2)

print(f"Preset '{preset_name}' removed from profile '{target_prof}'.")
EOF

  if is_rdns_active; then
    reload_rdns
    ok "Rules reloaded."
  fi
}

# --- Command: list-rules ---
cmd_list_rules() {
  if [[ ! -f "$RULES_FILE" ]]; then
    warn "Belum ada file rules konfigurasi."
    return 0
  fi

  python3 - <<'EOF'
import json

try:
    with open("/etc/rdns/rules.json", 'r') as f:
        rules = json.load(f)
except Exception:
    rules = {}

if not rules:
    print(" \033[1;33mBelum ada routing rules aktif.\033[0m")
else:
    for p, dlist in rules.items():
        print(f"\n \033[30;107m[ PROFIL: {p} ]\033[0m \033[1;32m({len(dlist)} Domain Rules)\033[0m")
        for i, d in enumerate(dlist, 1):
            print(f"   \033[38;5;205m(•{i:2d})\033[0m \033[1;37m│\033[0m {d}")
EOF
}

# --- Command: test-domain ---
cmd_test_domain() {
  local test_d="$1"
  test_d=$(echo "$test_d" | tr '[:upper:]' '[:lower:]' | sed 's/^[.]//')

  python3 - <<EOF
import json, sys

domain = "${test_d}"
try:
    with open("${RULES_FILE}", 'r') as f:
        rules = json.load(f)
except Exception:
    rules = {}

# Longest-suffix match logic
best_prof = None
best_len = 0
best_rule = None

for p, dlist in rules.items():
    for r in dlist:
        r = r.lower().strip('.')
        if domain == r or domain.endswith('.' + r):
            if len(r) > best_len:
                best_len = len(r)
                best_prof = p
                best_rule = r

if best_prof:
    print(" \033[1;32m[✓ STATUS: MATCH SUCCESS]\033[0m")
    print(f"   \033[1;37mDomain Diuji  :\033[0m \033[0;36m{domain}\033[0m")
    print(f"   \033[1;37mMatched Rule  :\033[0m \033[1;33m{best_rule}\033[0m")
    print(f"   \033[1;37mTarget Node   :\033[0m \033[1;32m[{best_prof}]\033[0m")
    print(f"   \033[1;37mRouting Path  :\033[0m \033[38;5;205mmTLS Yamux Tunnel ➔ Exit Node [{best_prof}]\033[0m")
else:
    print(" \033[1;33m[○ STATUS: DIRECT / NO MATCH]\033[0m")
    print(f"   \033[1;37mDomain Diuji  :\033[0m \033[0;36m{domain}\033[0m")
    print(f"   \033[1;37mRouting Path  :\033[0m \033[0;37mDirect (Default DNS Upstream Lokal VPS)\033[0m")
EOF
}

# --- Command: remove-profile ---
cmd_remove_profile() {
  local profile="$1"
  python3 - <<EOF
import yaml, json

cfg_path = "${CONFIG_FILE}"
rules_path = "${RULES_FILE}"

try:
    with open(cfg_path, 'r') as f:
        cfg = yaml.safe_load(f) or {}
    profiles = [p for p in cfg.get('profiles', []) if p.get('name') != "${profile}"]
    cfg['profiles'] = profiles
    with open(cfg_path, 'w') as f:
        yaml.dump(cfg, f, default_flow_style=False)
except Exception as e:
    print("Config update error:", e)

try:
    with open(rules_path, 'r') as f:
        rules = json.load(f)
    if "${profile}" in rules:
        del rules["${profile}"]
    with open(rules_path, 'w') as f:
        json.dump(rules, f, indent=2)
except Exception as e:
    print("Rules update error:", e)

print(f"Profile '${profile}' removed.")
EOF

  rm -f "${CERTS_DIR}/${profile}.crt" "${CERTS_DIR}/${profile}.key" "${CERTS_DIR}/${profile}-ca.crt"
  if is_rdns_active; then
    start_and_verify_rdns || true
  fi
}

# --- Command: status ---
cmd_status() {
  ui_header "RDNS CLIENT STATUS & RUNTIME"
  ui_kv "Credit" "github: @risqinf" "$PINK"
  ui_rule

  if is_rdns_active; then
    print_health_summary
  else
    echo -e "   ${RED}[✗]${NC} ${WHITE}Service rdns-client :${NC} ${RED}INACTIVE / STOPPED${NC}"
    echo ""
    if [[ -s /var/log/rdns-client.log ]]; then
      echo -e " ${CYAN}Log Terakhir /var/log/rdns-client.log:${NC}"
      tail -n 8 /var/log/rdns-client.log 2>/dev/null || true
    fi
  fi
  ui_rule

  if [[ -f "$CONFIG_FILE" ]]; then
    python3 - <<'EOF'
import yaml, json, os

cfg_file = "/etc/rdns/client.yaml"
rules_file = "/etc/rdns/rules.json"

try:
    with open(cfg_file, 'r') as f:
        cfg = yaml.safe_load(f) or {}
    profiles = cfg.get('profiles', [])
except Exception:
    profiles = []

try:
    with open(rules_file, 'r') as f:
        rules = json.load(f) or {}
except Exception:
    rules = {}

print(f" \033[1;37mProfil Terdaftar :\033[0m \033[0;36m{len(profiles)} node(s)\033[0m")
for p in profiles:
    name = p.get('name', 'N/A')
    r_count = len(rules.get(name, []))
    print(f"   \033[38;5;205m•\033[0m \033[1;32m{name}\033[0m ➔ Server: \033[0;36m{p.get('server')}\033[0m (Rules: \033[1;33m{r_count} domains\033[0m)")
EOF
  fi
  ui_foot
}

# --- Command: doctor ---
cmd_doctor() {
  ui_header "RDNS SYSTEM DOCTOR & DIAGNOSTICS"
  ui_kv "Credit" "github: @risqinf" "$PINK"
  ui_rule

  echo -e " ${WHITE}Memeriksa integritas dependensi dan konfigurasi...${NC}\n"

  # 1. Binary check
  if [[ -x /usr/local/bin/rdns-client ]]; then
    local ver
    ver=$(/usr/local/bin/rdns-client --version 2>&1 || echo "unknown")
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Binary rdns-client  :${NC} ${GREEN}/usr/local/bin/rdns-client (${ver})${NC}"
  else
    echo -e "   ${RED}[FAIL]${NC} ${WHITE}Binary rdns-client  :${NC} ${RED}TIDAK DITEMUKAN di /usr/local/bin/rdns-client${NC}"
  fi

  # 2. Service unit check
  if [[ -f /etc/systemd/system/rdns-client.service ]]; then
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Systemd Unit File   :${NC} ${GREEN}/etc/systemd/system/rdns-client.service${NC}"
  else
    echo -e "   ${YELLOW}[WARN]${NC} ${WHITE}Systemd Unit File   :${NC} ${YELLOW}Belum dibuat${NC}"
  fi

  # 3. Log file check
  if [[ -f /var/log/rdns-client.log ]]; then
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Log File Path       :${NC} ${GREEN}/var/log/rdns-client.log (Siap)${NC}"
  else
    echo -e "   ${YELLOW}[WARN]${NC} ${WHITE}Log File Path       :${NC} ${YELLOW}/var/log/rdns-client.log belum dibuat${NC}"
  fi

  # 4. Config files check
  if [[ -f "$CONFIG_FILE" ]]; then
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Config File         :${NC} ${GREEN}${CONFIG_FILE}${NC}"
  else
    echo -e "   ${YELLOW}[WARN]${NC} ${WHITE}Config File         :${NC} ${YELLOW}Belum ada profil dipairing${NC}"
  fi

  if [[ -f "$RULES_FILE" ]]; then
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Rules File          :${NC} ${GREEN}${RULES_FILE}${NC}"
  else
    echo -e "   ${YELLOW}[WARN]${NC} ${WHITE}Rules File          :${NC} ${YELLOW}${RULES_FILE} belum dibuat${NC}"
  fi

  # 5. Kernel & nftables check
  if command -v nft &>/dev/null; then
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Kernel Netfilter    :${NC} ${GREEN}nftables command line OK${NC}"
  else
    echo -e "   ${RED}[FAIL]${NC} ${WHITE}Kernel Netfilter    :${NC} ${RED}nft command tidak ditemukan!${NC}"
  fi

  # 6. Service active check
  if is_rdns_active; then
    echo -e "   ${GREEN}[PASS]${NC} ${WHITE}Runtime Status      :${NC} ${GREEN}Service Sedang Berjalan (Active)${NC}"
    print_health_summary
  else
    echo -e "   ${YELLOW}[INFO]${NC} ${WHITE}Runtime Status      :${NC} ${YELLOW}Service Belum Berjalan (Inactive)${NC}"
  fi

  ui_foot
}

# --- Command: restart ---
cmd_restart() {
  ensure_rdns_installed
  start_and_verify_rdns
}

# --- Command: logs ---
cmd_logs() {
  local follow="${1:-}"
  if [[ "$follow" == "-f" || "$follow" == "follow" ]]; then
    if [[ -f /var/log/rdns-client.log ]]; then
      tail -f /var/log/rdns-client.log
    elif command -v journalctl &>/dev/null; then
      journalctl -u rdns-client -f
    fi
  else
    if [[ -f /var/log/rdns-client.log ]]; then
      tail -n 35 /var/log/rdns-client.log
    elif command -v journalctl &>/dev/null; then
      journalctl -u rdns-client -n 35 --no-pager
    fi
  fi
}

cmd_update() {
  ui_rule
  echo -e " ${GREEN}MEMPERBARUI BINARY & INTEGRASI RDNS CLIENT...${NC}"
  ui_rule
  ensure_rdns_installed
  if [[ -f "$CONFIG_FILE" ]] && grep -q "0.0.0.0:5353" "$CONFIG_FILE" 2>/dev/null; then
    sed -i 's/0.0.0.0:5353/0.0.0.0:14053/g' "$CONFIG_FILE" 2>/dev/null || true
    info "Migrasi konfigurasi 5353 -> 14053 selesai."
  fi
  if is_rdns_active; then
    info "Merestart service rdns-client..."
    start_and_verify_rdns
  else
    ok "rdns-client siap digunakan. Versi: $(/usr/local/bin/rdns-client -version 2>/dev/null || echo 'v0.2.1')"
  fi
}

# --- CLI Dispatcher ---
case "${1:-}" in
  pair)
    shift; cmd_pair "$@"
    ;;
  add-rule)
    shift; cmd_add_rule "$@"
    ;;
  remove-rule)
    shift; cmd_remove_rule "$@"
    ;;
  load-preset)
    shift; cmd_load_preset "$@"
    ;;
  remove-preset)
    shift; cmd_remove_preset "$@"
    ;;
  list-rules)
    cmd_list_rules
    ;;
  test-domain)
    shift; cmd_test_domain "$@"
    ;;
  remove-profile)
    shift; cmd_remove_profile "$@"
    ;;
  status)
    cmd_status
    ;;
  doctor)
    cmd_doctor
    ;;
  restart)
    cmd_restart
    ;;
  logs)
    shift; cmd_logs "$@"
    ;;
  update)
    cmd_update
    ;;
  *)
    echo "RDNS Manager CLI (github: @risqinf)"
    echo "Usage: rdns-manager <pair|add-rule|remove-rule|load-preset|remove-preset|list-rules|test-domain|remove-profile|status|doctor|restart|logs|update>"
    exit 1
    ;;
esac
