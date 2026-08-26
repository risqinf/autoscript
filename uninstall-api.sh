#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Uninstaller for RESTful API Server only
# Developed for Rocky Linux 9 / Enterprise Linux
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_ok() { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

clear
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "           ${RED}AUTOSCRIPT RESTful API UNINSTALLER${NC}               "
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root!"
    exit 1
fi

print_warn "This will remove only the RESTful API server (api-server.service, binary, and /etc/api/)."
print_warn "Your VPN core (Xray, Dropbear, HAProxy, Nginx, SQLite database) will NOT be touched."
echo ""
read -rp "Are you sure you want to delete the RESTful API? [y/N]: " confirm
if [[ "${confirm,,}" != "y" && "${confirm,,}" != "yes" ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

echo ""
print_info "[1/4] Stopping and disabling api-server service..."
systemctl stop api-server 2>/dev/null || true
systemctl disable api-server 2>/dev/null || true
print_ok "api-server service stopped."

print_info "[2/4] Removing systemd unit files..."
rm -f /etc/systemd/system/api-server.service
systemctl daemon-reload
print_ok "Systemd service removed."

print_info "[3/4] Removing API binaries..."
rm -f /usr/local/bin/api-server
rm -f /usr/local/bin/autoscript-api
print_ok "Binaries removed."

print_info "[4/4] Removing API database & configurations..."
rm -rf /etc/api
print_ok "API database directory /etc/api removed."

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
print_ok "RESTful API has been successfully uninstalled!"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
