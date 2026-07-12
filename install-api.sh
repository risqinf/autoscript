#!/bin/bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Build and install API server
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script must be run as root!"
    exit 1
fi

# Check if Go is installed
if ! command -v go &>/dev/null; then
    print_info "Installing Go..."
    dnf install -y golang >/dev/null 2>&1 || {
        print_error "Failed to install Go"
        exit 1
    }
    print_ok "Go installed"
fi

# Get Go version
GO_VERSION=$(go version | awk '{print $3}')
print_info "Go version: $GO_VERSION"

# Set paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$SCRIPT_DIR/files"
BINARY_NAME="api-server"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
SERVICE_FILE="/etc/systemd/system/api-server.service"
API_DB_DIR="/etc/api"
API_DB_PATH="$API_DB_DIR/api.db"
MAIN_DB_PATH="/etc/xray/xray.db"

# Check if main database exists
if [ ! -f "$MAIN_DB_PATH" ]; then
    print_error "Main database not found: $MAIN_DB_PATH"
    print_error "Please run the main installer first"
    exit 1
fi

# Detect system resources for resource-limited compilation
CPU_CORES=$(nproc 2>/dev/null || echo 1)
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)

# Calculate build limits based on available resources
# Goal: compile successfully on 512MB-1GB VPS without OOM
if (( RAM_MB <= 512 )); then
    # Very low RAM: single thread, aggressive GC, minimal parallelism
    GOMAXPROCS=1
    GOGC=30
    BUILD_PARALLEL=1
    BUILD_TAGS=""
    print_info "Low RAM detected (${RAM_MB}MB): using minimal build settings"
elif (( RAM_MB <= 1024 )); then
    # 1GB RAM: single thread, moderate GC
    GOMAXPROCS=1
    GOGC=50
    BUILD_PARALLEL=1
    BUILD_TAGS=""
    print_info "Standard RAM detected (${RAM_MB}MB): using balanced build settings"
elif (( RAM_MB <= 2048 )); then
    # 2GB RAM: can use 2 cores
    GOMAXPROCS=$((CPU_CORES > 2 ? 2 : CPU_CORES))
    GOGC=75
    BUILD_PARALLEL=2
    BUILD_TAGS=""
    print_info "Good RAM detected (${RAM_MB}MB): using faster build settings"
else
    # 4GB+: use all cores
    GOMAXPROCS=$CPU_CORES
    GOGC=100
    BUILD_PARALLEL=$CPU_CORES
    BUILD_TAGS=""
    print_info "High RAM detected (${RAM_MB}MB): using maximum build settings"
fi

# Check swap availability
SWAP_MB=$(free -m | awk '/Swap/ {print $2}' 2>/dev/null || echo 0)
if (( SWAP_MB > 0 )); then
    print_info "Swap available: ${SWAP_MB}MB"
else
    print_warn "No swap detected - build may fail on low RAM"
fi

# Build API server
print_info "Building API server..."
cd "$API_DIR"

# Download dependencies
print_info "Downloading dependencies..."
go mod tidy >/dev/null 2>&1

# Build binary with resource limits
print_info "Compiling binary (GOMAXPROCS=$GOMAXPROCS, GOGC=$GOGC, -p $BUILD_PARALLEL)..."
export GOMAXPROCS=$GOMAXPROCS
export GOGC=$GOGC

# Use -p to limit parallel compilation, -ldflags to reduce binary size
CGO_ENABLED=0 go build \
    -p $BUILD_PARALLEL \
    -ldflags="-s -w" \
    -o "$INSTALL_PATH" \
    ./cmd/server

if [ ! -f "$INSTALL_PATH" ]; then
    print_error "Build failed!"
    print_error "If OOM, try: dnf install -y epel-release && dnf install -y zram-generator-defaults"
    exit 1
fi

chmod +x "$INSTALL_PATH"
print_ok "Binary built and installed: $INSTALL_PATH"

# Create API database directory
print_info "Creating API database directory..."
mkdir -p "$API_DB_DIR"
chmod 700 "$API_DB_DIR"
print_ok "API directory created: $API_DB_DIR"

# Install systemd service
print_info "Installing systemd service..."
cp "$API_DIR/api-server.service" "$SERVICE_FILE"
chmod 644 "$SERVICE_FILE"
systemctl daemon-reload
print_ok "Systemd service installed"

# Enable and start service
print_info "Starting API server..."
systemctl enable api-server --now >/dev/null 2>&1

# Wait for service to start
sleep 2

# Check if service is running
if systemctl is-active --quiet api-server; then
    print_ok "API server is running"
else
    print_warn "API server failed to start, checking logs..."
    journalctl -u api-server --no-pager -n 20
    exit 1
fi

# Get the default token from logs
print_info "Retrieving API token..."
TOKEN=$(journalctl -u api-server --no-pager -n 50 | grep "default API token created" | tail -1 | awk -F': ' '{print $NF}')

if [ -n "$TOKEN" ]; then
    print_ok "API token generated"
    echo ""
    echo -e "${GREEN}=== API SERVER INSTALLED ===${NC}"
    echo -e "${BLUE}Endpoint:${NC} http://127.0.0.1:9000"
    echo -e "${BLUE}Token:${NC}    $TOKEN"
    echo ""
    echo -e "${YELLOW}Save this token! You'll need it for API requests.${NC}"
    echo ""
else
    print_warn "Could not retrieve token from logs"
    print_info "Check: journalctl -u api-server"
fi

# Test health endpoint
print_info "Testing health endpoint..."
HEALTH=$(curl -s http://127.0.0.1:9000/api/v1/health 2>/dev/null)
if echo "$HEALTH" | grep -q '"success":true'; then
    print_ok "Health check passed"
else
    print_warn "Health check failed (this is normal if nginx/haproxy not configured yet)"
fi

echo ""
print_ok "API server installation complete!"
echo ""
echo -e "${BLUE}Usage:${NC}"
echo "  curl -H 'Authorization: Bearer <token>' http://127.0.0.1:9000/api/v1/status"
echo ""
echo -e "${BLUE}Documentation:${NC} files/README.md"
echo ""
