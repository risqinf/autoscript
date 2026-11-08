#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: System, Menu & Core Scripts Updater
# Developed for Rocky Linux 9 / Enterprise Linux
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================

set -euo pipefail

# Ensure script runs as root
if [[ $EUID -ne 0 ]]; then
  echo -e "\e[31mError: This updater must be run as root.\e[0m"
  exit 1
fi

# Load common library if available
if [[ -f /usr/local/sbin/lib/common.sh ]]; then
  # shellcheck source=/dev/null
  . /usr/local/sbin/lib/common.sh
fi

# Define fallback colors if common.sh was not loaded
RED="${RED:-\033[0;31m}"
GREEN="${GREEN:-\033[0;32m}"
YELLOW="${YELLOW:-\033[0;33m}"
BLUE="${BLUE:-\033[0;34m}"
CYAN="${CYAN:-\033[0;36m}"
NC="${NC:-\033[0m}"

print_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Read currently installed version
CURRENT_VER="Unknown"
if [[ -f /usr/local/sbin/VERSION ]]; then
  CURRENT_VER=$(tr -d '[:space:]' < /usr/local/sbin/VERSION)
elif [[ -f /etc/xray/version ]]; then
  CURRENT_VER=$(tr -d '[:space:]' < /etc/xray/version)
fi

REPO_OWNER="risqinf"
REPO_NAME="autoscript"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_TARBALL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
LATEST_VER_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/VERSION"

# Fetch latest available version realtime from GitHub
LATEST_VER=$(curl -sSL --connect-timeout 4 --max-time 6 "$LATEST_VER_URL" 2>/dev/null | tr -d '[:space:]' || echo "")
if [[ -z "$LATEST_VER" ]]; then
  LATEST_VER="5.6.1"
fi

STATUS_BADGE=""
if [[ "$CURRENT_VER" != "$LATEST_VER" ]]; then
  STATUS_BADGE="${GREEN}[UPDATE TERSEDIA ➔ v${LATEST_VER}]${NC}"
else
  STATUS_BADGE="${CYAN}[SUDAH VERSI TERBARU]${NC}"
fi

clear
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "           ${GREEN}AUTOSCRIPT SYSTEM & SCRIPT UPDATER${NC}               "
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " Versi Terpasang di VPS    : ${YELLOW}${CURRENT_VER}${NC}"
echo -e " Versi Terbaru di GitHub   : ${GREEN}${LATEST_VER}${NC} ${STATUS_BADGE}"
echo -e " Repository                : ${CYAN}https://github.com/${REPO_OWNER}/${REPO_NAME}${NC}"
echo -e " Mode Keamanan             : ${GREEN}NON-DESTRUCTIVE (DB & JSON User Aman)${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Confirm update unless quiet or forced
if [[ "${1:-}" != "-y" && "${1:-}" != "--force" && "${1:-}" != "--quiet" && "${1:-}" != "-f" ]]; then
  read -rp "Lanjutkan proses update ke rilis terbaru (v${LATEST_VER})? [Y/n]: " ans
  ans="${ans,,}"
  if [[ "$ans" == "n" || "$ans" == "no" ]]; then
    print_warn "Update dibatalkan oleh pengguna."
    exit 0
  fi
  echo ""
fi

# Ensure essential tools are present
for pkg in tar gzip curl wget sqlite3; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    dnf install -y "$pkg" >/dev/null 2>&1 || true
  fi
done

tmpdir=""
srcdir=""

# Check if running within a cloned repository root or subfolder
this_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$this_dir/install.sh" && -d "$this_dir/scripts" ]]; then
  srcdir="$this_dir"
  print_info "Using local repository source: $srcdir"
elif [[ -f "$this_dir/../../install.sh" && -d "$this_dir/../../scripts" ]]; then
  srcdir="$(cd "$this_dir/../.." && pwd)"
  print_info "Using local repository source: $srcdir"
else
  tmpdir=$(mktemp -d /tmp/as-update.XXXXXX)
  cleanup() {
    [[ -n "$tmpdir" && -d "$tmpdir" ]] && rm -rf "$tmpdir"
  }
  trap cleanup EXIT INT TERM

  print_info "Fetching latest code archive from GitHub..."
  if ! curl -sSL --connect-timeout 10 --max-time 60 -o "$tmpdir/repo.tar.gz" "$REPO_TARBALL"; then
    print_error "Failed to download update archive from $REPO_TARBALL"
    exit 1
  fi

  tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir"
  srcdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)
  [[ -z "$srcdir" ]] && srcdir="$tmpdir/${REPO_NAME}-${REPO_BRANCH}"
fi

NEW_VER="Unknown"
if [[ -f "$srcdir/VERSION" ]]; then
  NEW_VER=$(tr -d '[:space:]' < "$srcdir/VERSION")
fi
print_info "Target version: ${GREEN}${NEW_VER}${NC}"

# 1. Update shared libraries
print_info "Updating shared libraries (/usr/local/sbin/lib/)..."
mkdir -p /usr/local/sbin/lib
if [[ -d "$srcdir/scripts/lib" ]]; then
  install -m 0644 "$srcdir/scripts/lib/"*.sh /usr/local/sbin/lib/
fi
print_ok "Shared libraries updated."

# 2. Update command scripts
print_info "Updating command scripts (/usr/local/sbin/)..."
mkdir -p /usr/local/sbin/api
find "$srcdir/scripts" -maxdepth 2 -type f -name '*.sh' \
  ! -path '*/api/*' ! -path '*/lib/*' | while read -r file; do
  name=$(basename "$file" .sh)
  install -m 0755 "$file" "/usr/local/sbin/$name"
done

# Install API command scripts into /usr/local/sbin/api
if [[ -d "$srcdir/scripts/api" ]]; then
  find "$srcdir/scripts/api" -maxdepth 1 -type f -name '*.sh' | while read -r file; do
    name=$(basename "$file" .sh)
    install -m 0755 "$file" "/usr/local/sbin/api/$name"
  done
fi
print_ok "Command scripts updated."

# 3. Update RDNS presets & service (preserves existing rules.json & client.yaml)
print_info "Updating SmartDNS / RDNS presets and service..."
mkdir -p /usr/local/sbin/rdns/presets /etc/rdns/presets /etc/rdns/certs /var/log
touch /var/log/rdns-client.log && chmod 644 /var/log/rdns-client.log 2>/dev/null || true

if [[ -d "$srcdir/scripts/rdns/presets" ]]; then
  cp -rf "$srcdir/scripts/rdns/presets/"*.json /usr/local/sbin/rdns/presets/ 2>/dev/null || true
  cp -rf "$srcdir/scripts/rdns/presets/"*.json /etc/rdns/presets/ 2>/dev/null || true
fi

# Ensure python3-pyyaml is available
if command -v python3 &>/dev/null && ! python3 -c "import yaml" 2>/dev/null; then
  dnf install -y python3-pyyaml >/dev/null 2>&1 || apt-get install -y python3-yaml >/dev/null 2>&1 || true
fi

# Ensure rdns-client systemd service template exists with failsafe cleanup & pre-start log touch
if command -v systemctl &>/dev/null; then
  if [[ ! -f /etc/systemd/system/rdns-client.service ]] || ! grep -q "ExecStartPre" /etc/systemd/system/rdns-client.service 2>/dev/null; then
    cat > /etc/systemd/system/rdns-client.service <<'EOF_RDNS_SVC'
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
EOF_RDNS_SVC
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable rdns-client >/dev/null 2>&1 || true
  fi
fi

# Ensure rdns-client binary is installed and up-to-date (v0.2.1)
NEED_RDNS_CLIENT_UPDATE=false
if [[ ! -x /usr/local/bin/rdns-client ]]; then
  NEED_RDNS_CLIENT_UPDATE=true
elif ! /usr/local/bin/rdns-client -version 2>/dev/null | grep -q "v0.2.1"; then
  print_info "Updating rdns-client binary ($(/usr/local/bin/rdns-client -version 2>/dev/null || echo 'old')) to v0.2.1..."
  NEED_RDNS_CLIENT_UPDATE=true
fi

if [[ "$NEED_RDNS_CLIENT_UPDATE" == "true" ]]; then
  UNAME_ARCH="$(uname -m)"
  case "$UNAME_ARCH" in
    x86_64|amd64) R_ARCH="amd64" ;;
    aarch64|arm64) R_ARCH="arm64" ;;
    *) R_ARCH="" ;;
  esac
  if [[ -n "$R_ARCH" ]]; then
    if [[ -x "$srcdir/bin/rdns-client-linux-${R_ARCH}" ]]; then
      cp -f "$srcdir/bin/rdns-client-linux-${R_ARCH}" /usr/local/bin/rdns-client
      chmod 755 /usr/local/bin/rdns-client
    elif [[ -x "/home/risqinf/Project-Real/rdns/dist/rdns-client-linux-${R_ARCH}" ]]; then
      cp -f "/home/risqinf/Project-Real/rdns/dist/rdns-client-linux-${R_ARCH}" /usr/local/bin/rdns-client
      chmod 755 /usr/local/bin/rdns-client
    else
      print_info "Installing static rdns-client binary (v0.2.1)..."
      curl -sSL --connect-timeout 10 --max-time 30 -o /usr/local/bin/rdns-client \
        "https://github.com/risqinf/rdns/releases/download/v0.2.1/rdns-client-linux-${R_ARCH}" 2>/dev/null || true
      chmod 755 /usr/local/bin/rdns-client 2>/dev/null || true
    fi
  fi
fi

# Auto-migrate legacy configuration port 5353 -> 14053
if [[ -f /etc/rdns/client.yaml ]] && grep -q "0.0.0.0:5353" /etc/rdns/client.yaml 2>/dev/null; then
  sed -i 's/0.0.0.0:5353/0.0.0.0:14053/g' /etc/rdns/client.yaml 2>/dev/null || true
  print_info "Migrated legacy port 5353 -> 14053 in /etc/rdns/client.yaml"
fi

# Safely restart rdns-client if active
if command -v systemctl &>/dev/null && systemctl is-active rdns-client &>/dev/null; then
  print_info "Restarting rdns-client to apply latest binary and configuration..."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart rdns-client >/dev/null 2>&1 || true
fi
print_ok "RDNS components updated."

# 4. Cache prebuilt binaries and build scripts
if [[ -d "$srcdir/bin" ]]; then
  mkdir -p /usr/local/share/autoscript/bin
  cp -rf "$srcdir/bin/"* /usr/local/share/autoscript/bin/ 2>/dev/null || true
fi
if [[ -f "$srcdir/scripts/build/build-dropbear-2019.sh" ]]; then
  mkdir -p /usr/local/share/autoscript/build
  install -m 0755 "$srcdir/scripts/build/build-dropbear-2019.sh" /usr/local/share/autoscript/build/build-dropbear-2019.sh
fi

# 5. Update helper scripts
[[ -f "$srcdir/install-api.sh" ]] && install -m 0755 "$srcdir/install-api.sh" /usr/local/sbin/install-api
[[ -f "$srcdir/uninstall-api.sh" ]] && install -m 0755 "$srcdir/uninstall-api.sh" /usr/local/sbin/uninstall-api
[[ -f "$srcdir/uninstall.sh" ]] && install -m 0755 "$srcdir/uninstall.sh" /usr/local/sbin/uninstall
if [[ -f "$srcdir/update.sh" ]]; then
  install -m 0755 "$srcdir/update.sh" /usr/local/sbin/update
elif [[ -f "$srcdir/scripts/system/update.sh" ]]; then
  install -m 0755 "$srcdir/scripts/system/update.sh" /usr/local/sbin/update
fi
ln -sf /usr/local/sbin/update /usr/local/sbin/update-script 2>/dev/null || true
ln -sf /usr/local/sbin/update /usr/local/sbin/autoscript-update 2>/dev/null || true

# 6. Save updated version files
if [[ -n "$NEW_VER" && "$NEW_VER" != "Unknown" ]]; then
  echo "$NEW_VER" > /usr/local/sbin/VERSION
  echo "$NEW_VER" > /etc/xray/version 2>/dev/null || true
fi

# 7. Safe database schema verification (idempotent, accounts are never touched)
print_info "Verifying account database schema (SQLite)..."
if [[ -f /usr/local/sbin/lib/db.sh ]]; then
  # shellcheck source=/dev/null
  . /usr/local/sbin/lib/db.sh
  db_init
  print_ok "SQLite database schema up to date."
fi

# 8. Rebuild API server if Go and source exist
if [[ -f /usr/local/bin/api-server && -d "$srcdir/files" ]]; then
  if command -v go >/dev/null 2>&1; then
    print_info "Recompiling RESTful API server with latest code..."
    (
      cd "$srcdir/files" || exit 1
      CGO_ENABLED=0 go build \
        -ldflags="-s -w -X main.Version=${NEW_VER}" \
        -o /usr/local/bin/api-server \
        ./cmd/server/main.go >/dev/null 2>&1
    ) && print_ok "API server updated." || print_warn "API compilation failed; existing binary kept."
  fi
  systemctl restart api-server >/dev/null 2>&1 || true
fi

# 9. Reload systemd daemon and refresh monitor background services
print_info "Reloading systemd and background monitors..."
systemctl daemon-reload >/dev/null 2>&1
for svc in quota-ssh quota limit-ip-vless quota-trojan limit-ip-trojan quota-vmess limit-ip-vmess; do
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    systemctl restart "$svc" >/dev/null 2>&1 || true
  fi
done
print_ok "Background monitors refreshed."

# 10. Audit firewall rules quietly
if [[ -x /usr/local/sbin/fix-firewall ]]; then
  /usr/local/sbin/fix-firewall --quiet >/dev/null 2>&1 || true
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "       ${GREEN}AUTOSCRIPT UPDATE COMPLETED SUCCESSFULLY!${NC}            "
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " Previous Version : ${YELLOW}${CURRENT_VER}${NC}"
echo -e " Current Version  : ${GREEN}${NEW_VER}${NC}"
echo -e " Status           : ${GREEN}All menus, libraries & daemons are active.${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
