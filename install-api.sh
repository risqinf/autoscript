#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Enterprise RESTful API Server Installer & Builder
# Developed for Rocky Linux 9 / Enterprise Linux
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'
BOLD='\033[1m'

print_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
print_info()  { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

clear
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}           AUTOSCRIPT RESTful API INSTALLER                 ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root!"
    exit 1
fi

# Set paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$SCRIPT_DIR/files"
INSTALL_PATH="/usr/local/bin/api-server"
SERVICE_FILE="/etc/systemd/system/api-server.service"
API_DB_DIR="/etc/api"
API_DB_PATH="$API_DB_DIR/api.db"
MAIN_DB_PATH="/etc/xray/xray.db"

# GitHub repo for binary downloads
GITHUB_REPO="risqinf/autoscript"
APP_NAME="autoscript-api"

# Install necessary runtime dependencies
print_info "Checking system utilities..."
dnf install -y sqlite tar gzip curl wget openssl jq 2>/dev/null || \
    yum install -y sqlite tar gzip curl wget openssl jq 2>/dev/null || true

# Ensure API directory exists
mkdir -p "$API_DB_DIR"
chmod 700 "$API_DB_DIR"

# Copy helper scripts to /usr/local/sbin
if [[ -f "$SCRIPT_DIR/install-api.sh" ]]; then
    install -m 0755 "$SCRIPT_DIR/install-api.sh" /usr/local/sbin/install-api
fi
if [[ -f "$SCRIPT_DIR/uninstall-api.sh" ]]; then
    install -m 0755 "$SCRIPT_DIR/uninstall-api.sh" /usr/local/sbin/uninstall-api
fi

# ─────────────────────────────────────────────────────────────
# Detect system architecture → map to release asset label
# ─────────────────────────────────────────────────────────────
detect_arch() {
    local machine
    machine="$(uname -m)"
    case "$machine" in
        x86_64)           echo "linux-amd64" ;;
        aarch64|arm64)    echo "linux-arm64" ;;
        armv7l|armv7)     echo "linux-armv7" ;;
        armv6l)           echo "linux-armv7" ;;  # fallback armv7 for armv6
        *)
            print_warn "Unknown architecture: $machine. Will try compile from source."
            echo ""
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────
# Fetch latest release tag from GitHub API
# ─────────────────────────────────────────────────────────────
fetch_latest_release() {
    local api_url="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"
    local tag=""

    if command -v curl &>/dev/null; then
        tag=$(curl -fsSL --connect-timeout 10 --max-time 30 \
            -H "Accept: application/vnd.github+json" \
            "$api_url" 2>/dev/null \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    elif command -v wget &>/dev/null; then
        tag=$(wget -qO- --timeout=30 "$api_url" 2>/dev/null \
            | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
    fi

    echo "$tag"
}

# ─────────────────────────────────────────────────────────────
# Build download URL for a specific tag and arch label
# ─────────────────────────────────────────────────────────────
build_download_url() {
    local tag="$1"
    local arch_label="$2"
    echo "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${tag}-${arch_label}.tar.gz"
}

build_checksum_url() {
    local tag="$1"
    local arch_label="$2"
    echo "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${APP_NAME}-${tag}-${arch_label}.sha256"
}

# ─────────────────────────────────────────────────────────────
# Download, verify, and install prebuilt binary from release
# Returns 0 on success, 1 on failure
# ─────────────────────────────────────────────────────────────
install_binary_from_release() {
    local tag="$1"
    local arch_label="$2"

    local dl_url
    local cs_url
    dl_url="$(build_download_url "$tag" "$arch_label")"
    cs_url="$(build_checksum_url "$tag" "$arch_label")"

    local tmpdir
    tmpdir="$(mktemp -d /tmp/autoscript-api-XXXXXX)"
    trap 'rm -rf "$tmpdir"' RETURN

    local archive="${tmpdir}/${APP_NAME}-${tag}-${arch_label}.tar.gz"
    local binary_name="${APP_NAME}-${tag}-${arch_label}"

    print_info "Downloading binary: ${dl_url}"
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 15 --max-time 120 \
            -o "$archive" "$dl_url" || { print_warn "Download failed."; return 1; }
    else
        wget -qO "$archive" --timeout=120 "$dl_url" || { print_warn "Download failed."; return 1; }
    fi

    if [[ ! -f "$archive" || ! -s "$archive" ]]; then
        print_warn "Downloaded archive is empty or missing."
        return 1
    fi

    # Verify checksum if possible
    print_info "Verifying checksum..."
    local checksum_file="${tmpdir}/${binary_name}.sha256"
    if command -v curl &>/dev/null; then
        curl -fsSL --connect-timeout 10 --max-time 30 \
            -o "$checksum_file" "$cs_url" 2>/dev/null || true
    else
        wget -qO "$checksum_file" --timeout=30 "$cs_url" 2>/dev/null || true
    fi

    # Extract archive
    print_info "Extracting archive..."
    tar -xzf "$archive" -C "$tmpdir" || { print_warn "Failed to extract archive."; return 1; }

    local extracted_bin="${tmpdir}/${binary_name}"
    if [[ ! -f "$extracted_bin" ]]; then
        # Try finding the binary inside the extracted content
        extracted_bin=$(find "$tmpdir" -maxdepth 2 -type f -name "${APP_NAME}-*" ! -name "*.sha256" ! -name "*.tar.gz" | head -1)
    fi

    if [[ -z "$extracted_bin" || ! -f "$extracted_bin" ]]; then
        print_warn "Could not find binary in extracted archive."
        return 1
    fi

    # Verify sha256 if checksum file was downloaded
    if [[ -f "$checksum_file" && -s "$checksum_file" ]]; then
        local expected_hash
        expected_hash=$(awk '{print $1}' "$checksum_file")
        local actual_hash
        actual_hash=$(sha256sum "$extracted_bin" | awk '{print $1}')
        if [[ "$expected_hash" != "$actual_hash" ]]; then
            print_warn "Checksum mismatch! Expected: ${expected_hash}, Got: ${actual_hash}"
            return 1
        fi
        print_ok "Checksum verified: OK"
    else
        print_warn "Checksum file unavailable — skipping verification."
    fi

    # Install binary
    install -m 0755 "$extracted_bin" "$INSTALL_PATH"
    ln -sf "$INSTALL_PATH" /usr/local/bin/autoscript-api

    print_ok "Binary installed: $INSTALL_PATH (${tag} / ${arch_label})"
    return 0
}

# ─────────────────────────────────────────────────────────────
# Main: Try prebuilt binary first, fallback to compile
# ─────────────────────────────────────────────────────────────
BINARY_INSTALLED=0
ARCH_LABEL="$(detect_arch)"

# ── Step 1: Try latest GitHub Release binary ─────────────────
if [[ -n "$ARCH_LABEL" ]]; then
    print_info "Checking latest release from GitHub (${GITHUB_REPO})..."
    LATEST_TAG="$(fetch_latest_release)"

    if [[ -n "$LATEST_TAG" ]]; then
        print_info "Latest release found: ${LATEST_TAG}"
        print_info "Architecture detected: ${ARCH_LABEL}"

        if install_binary_from_release "$LATEST_TAG" "$ARCH_LABEL"; then
            BINARY_INSTALLED=1
        else
            print_warn "Failed to install prebuilt binary. Falling back to compile from source..."
        fi
    else
        print_warn "Could not fetch latest release from GitHub. Falling back to compile from source..."
    fi
else
    print_warn "Architecture not supported for prebuilt binary. Will compile from source."
fi

# ── Step 2: Fallback — compile from source ───────────────────
if [[ $BINARY_INSTALLED -eq 0 ]]; then
    if [[ -d "$API_DIR" && -f "$API_DIR/go.mod" ]]; then
        print_info "Source directory detected at $API_DIR"

        if ! command -v go &>/dev/null; then
            print_info "Installing Go compiler..."
            dnf install -y golang 2>/dev/null || yum install -y golang 2>/dev/null || \
                print_warn "Failed to install Go via package manager."
        fi

        if command -v go &>/dev/null; then
            GO_VERSION=$(go version | awk '{print $3}')
            print_info "Go compiler ready: $GO_VERSION"

            # Detect system resources for resource-limited compilation
            CPU_CORES=$(nproc 2>/dev/null || echo 1)
            RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)

            if (( RAM_MB <= 512 )); then
                GOMAXPROCS=1; GOGC=30; BUILD_PARALLEL=1
            elif (( RAM_MB <= 1024 )); then
                GOMAXPROCS=1; GOGC=50; BUILD_PARALLEL=1
            elif (( RAM_MB <= 2048 )); then
                GOMAXPROCS=$((CPU_CORES > 2 ? 2 : CPU_CORES)); GOGC=75; BUILD_PARALLEL=2
            else
                GOMAXPROCS=$CPU_CORES; GOGC=100; BUILD_PARALLEL=$CPU_CORES
            fi

            print_info "Compiling API server (GOMAXPROCS=$GOMAXPROCS, GOGC=$GOGC, -p $BUILD_PARALLEL)..."
            export GOMAXPROCS=$GOMAXPROCS
            export GOGC=$GOGC

            cd "$API_DIR"
            go mod tidy

            CGO_ENABLED=0 go build \
                -p $BUILD_PARALLEL \
                -ldflags="-s -w" \
                -o "$INSTALL_PATH" \
                ./cmd/server/main.go

            if [[ -f "$INSTALL_PATH" ]]; then
                chmod +x "$INSTALL_PATH"
                # Link also as autoscript-api
                ln -sf "$INSTALL_PATH" /usr/local/bin/autoscript-api
                BINARY_INSTALLED=1
                print_ok "API binary compiled and installed: $INSTALL_PATH"
            fi
        else
            print_error "Go compiler not available. Cannot compile from source."
        fi
    else
        print_warn "No source directory found at $API_DIR."
    fi
fi

if [[ $BINARY_INSTALLED -eq 0 && ! -f "$INSTALL_PATH" ]]; then
    print_error "Failed to build or download api-server binary."
    exit 1
fi

# Install systemd service
print_info "Installing systemd service..."
cat >"$SERVICE_FILE" <<'EOF'
[Unit]
Description=Autoscript VPN API Server
After=network.target xray.service dropbear.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/root
Environment=API_PORT=9000
Environment=API_HOST=127.0.0.1
Environment=API_DB_PATH=/etc/api/api.db
Environment=MAIN_DB_PATH=/etc/xray/xray.db
Environment=XRAY_CONFIG=/etc/xray/config.json
Environment=XRAY_BIN=/usr/local/bin/xray
ExecStart=/usr/local/bin/api-server
Restart=always
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

chmod 644 "$SERVICE_FILE"
systemctl daemon-reload
print_ok "Systemd service configured: $SERVICE_FILE"

# Ensure Token Exists in SQLite
print_info "Checking API authentication tokens..."
EXISTING_TOKEN=$(sqlite3 "$API_DB_PATH" "SELECT token FROM tokens ORDER BY id DESC LIMIT 1;" 2>/dev/null || true)
if [[ -z "$EXISTING_TOKEN" ]]; then
    if [[ -f /etc/api/key ]]; then
        EXISTING_TOKEN=$(head -n 1 /etc/api/key | tr -d '\r\n')
    else
        EXISTING_TOKEN=$(openssl rand -hex 32 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 64)
    fi
    sqlite3 "$API_DB_PATH" "CREATE TABLE IF NOT EXISTS tokens (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      token TEXT NOT NULL UNIQUE,
      created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
      last_used INTEGER NOT NULL DEFAULT 0
    );" 2>/dev/null || true
    sqlite3 "$API_DB_PATH" "INSERT INTO tokens (name, token, created_at) VALUES ('default', '$EXISTING_TOKEN', strftime('%s','now'));" 2>/dev/null || true
    echo "$EXISTING_TOKEN" > /etc/api/key
    chmod 600 /etc/api/key
fi

# Enable and start service
print_info "Starting API server service..."
systemctl enable api-server --now
sleep 1

# Verify service
if systemctl is-active --quiet api-server; then
    print_ok "API server is running actively!"
else
    print_warn "API server service did not start immediately. Checking logs:"
    journalctl -u api-server --no-pager -n 15 || true
fi

# Display summary
DOMAIN="127.0.0.1"
[[ -f /etc/xray/domain ]] && DOMAIN=$(cat /etc/xray/domain)

# Get installed version info
INSTALLED_VERSION="$("$INSTALL_PATH" --version 2>/dev/null || echo "unknown")"

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}${BOLD}           API SERVER INSTALLATION SUCCESSFUL!              ${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${WHITE}Version${NC}         : ${CYAN}${LATEST_TAG:-from-source}${NC}"
echo -e " ${WHITE}Endpoint Local${NC}  : ${CYAN}http://127.0.0.1:9000${NC}"
echo -e " ${WHITE}Endpoint Public${NC} : ${CYAN}https://${DOMAIN}${NC}"
echo -e " ${WHITE}Health Check${NC}    : ${CYAN}https://${DOMAIN}/api/health${NC}"
echo -e " ${YELLOW}Active Bearer Token:${NC}"
echo -e " ${GREEN}${BOLD}${EXISTING_TOKEN}${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e " ${WHITE}Quick Commands:${NC}"
echo -e "   - Open API Menu    : ${CYAN}menu-api${NC}"
echo -e "   - Restart API      : ${CYAN}systemctl restart api-server${NC}"
echo -e "   - Uninstall API    : ${CYAN}uninstall-api${NC}"
echo ""
