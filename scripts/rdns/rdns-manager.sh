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

RDNS_DIR="/etc/rdns"
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
mkdir -p "$CERTS_DIR"

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

ensure_base_config() {
  local profile_name="$1"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    info "Generating base configuration: $CONFIG_FILE..."
    cat >"$CONFIG_FILE" <<EOF
listen:
  dns:  "0.0.0.0:5353"
  sni:  "0.0.0.0:14300"
  quic: "0.0.0.0:14400"

rules: "${RULES_FILE}"

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
  fi

  if [[ ! -f "$RULES_FILE" ]]; then
    echo "{}" >"$RULES_FILE"
    chmod 644 "$RULES_FILE"
  fi
}

# --- Command: pair ---
cmd_pair() {
  local token="${1:-}"
  if [[ -z "$token" ]]; then
    err "Pairing token is required."
    echo "Usage: rdns-manager pair <rdns://...>"
    exit 1
  fi

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
  info "Restarting or reloading rdns-client service..."
  if systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || systemctl restart rdns-client 2>/dev/null || true
    ok "rdns-client reloaded."
  else
    systemctl restart rdns-client 2>/dev/null || true
    ok "rdns-client started."
  fi
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

  if systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || true
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

  if systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || true
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

print(f"Preset '{preset}' ({len(preset_domains)} domains) applied to profile '{target_prof}'.")
EOF

  if systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || true
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

print(f"Preset '{preset}' removed from profile '{target_prof}'.")
EOF

  if systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || true
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
  if systemctl is-active rdns-client &>/dev/null; then
    systemctl reload rdns-client 2>/dev/null || true
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
  *)
    echo "RDNS Manager CLI (github: @risqinf)"
    echo "Usage: rdns-manager <pair|add-rule|remove-rule|load-preset|remove-preset|list-rules|test-domain|remove-profile>"
    exit 1
    ;;
esac
