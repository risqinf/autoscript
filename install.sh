#!/bin/bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Developed for Rocky Linux 9
# Version: 0.2.0-beta
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
AS_VERSION="0.2.0-beta"
# --- Color Definitions ---
NC='\033[0m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
LIGHT='\033[0;37m'

# --- UI Helpers ---
print_header() {
    clear
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${PURPLE}         ◎ ENTERPRISE VPN AUTOSCRIPT INSTALLER ◎            ${NC}"
    echo -e "${PURPLE}                    version ${AS_VERSION}                     ${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() { echo -e "${GREEN}[OK]${NC} $1"; }
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Verify a service is active after enable/start. Usage: check_service <name> [fatal]
# If the second arg is "fatal", abort installation when the service is not active.
check_service() {
    local svc="$1"
    local fatal="${2:-}"
    if systemctl is-active --quiet "$svc"; then
        print_success "Service '$svc' is active."
        return 0
    fi
    print_error "Service '$svc' failed to start."
    systemctl status "$svc" --no-pager -l 2>/dev/null | head -n 15
    if [[ "$fatal" == "fatal" ]]; then
        print_error "Critical service '$svc' is not running. Aborting installation."
        exit 1
    fi
    return 1
}

show_progress() {
    local duration=$1
    local col=$(tput cols)
    local width=$((col - 20))
    echo -ne "  Progress: ["
    for ((i=0; i<width; i++)); do echo -ne " "; done
    echo -ne "] 0%"
    for ((i=0; i<=width; i++)); do
        local per=$((i * 100 / width))
        echo -ne "\r  Progress: ["
        for ((j=0; j<i; j++)); do echo -ne "■"; done
        for ((j=i; j<width; j++)); do echo -ne " "; done
        echo -ne "] $per%"
        sleep 0.05
    done
    echo -e "\n"
}

# ========================================================
# Resource detection & auto-tuning (RAM/CPU aware)
# Sets globals used by sysctl, nginx, haproxy, xray, and swap so the stack
# fits a 1 CPU / 1 GB VPS yet scales up on larger machines.
# ========================================================
detect_resources() {
    CPU_CORES=$(nproc 2>/dev/null); [[ "$CPU_CORES" =~ ^[0-9]+$ ]] || CPU_CORES=1
    RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
    [[ "$RAM_MB" =~ ^[0-9]+$ ]] || RAM_MB=1024

    # Tier by total RAM.
    if   (( RAM_MB <= 1280 )); then
        TIER="1GB";   NGX_CONN=4096;   HA_MAXCONN=8192;    NET_BUF=16777216;  XRAY_NOFILE=262144
    elif (( RAM_MB <= 2560 )); then
        TIER="2GB";   NGX_CONN=16384;  HA_MAXCONN=32768;   NET_BUF=33554432;  XRAY_NOFILE=524288
    elif (( RAM_MB <= 5120 )); then
        TIER="4GB";   NGX_CONN=65535;  HA_MAXCONN=100000;  NET_BUF=67108864;  XRAY_NOFILE=1000000
    else
        TIER="8GB+";  NGX_CONN=131072; HA_MAXCONN=200000;  NET_BUF=134217728; XRAY_NOFILE=1000000
    fi

    # nginx: one worker per core; rlimit must cover all connections per worker
    # (cap so cores*conn doesn't exceed the system fd ceiling unreasonably).
    NGX_WORKERS=$CPU_CORES
    NGX_RLIMIT=$(( NGX_CONN + 1024 ))
    # System-wide fd ceiling for the file-max sysctl.
    FILE_MAX=$(( (NGX_CONN * CPU_CORES) + 100000 ))
    (( FILE_MAX < 262144 )) && FILE_MAX=262144

    # TCP buffer auto-tune ceilings scale with the tier.
    TCP_RMEM_MAX=$NET_BUF
    TCP_WMEM_MAX=$NET_BUF
}

# Check if the user is root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root!${NC}"
  exit 1
fi

detect_resources

# Password Root Change
print_header
echo -e "${LIGHT}Preparation: Security Hardening${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
while true; do
    read -rsp "Enter new root password: " root_pass; echo
    if [[ -z "$root_pass" ]]; then
        print_error "Root password cannot be empty."
        continue
    fi
    if [[ ${#root_pass} -lt 8 ]]; then
        print_warn "Password is shorter than 8 characters. Use a stronger one."
    fi
    read -rsp "Confirm new root password: " root_pass2; echo
    [[ "$root_pass" == "$root_pass2" ]] && break
    print_error "Passwords do not match. Try again."
done
echo "root:$root_pass" | chpasswd
print_success "Root password updated successfully."

# Backup encryption password (stored securely in /etc/xray)
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
mkdir -p /etc/xray
chmod 700 /etc/xray
while true; do
    read -rsp "Enter backup encryption password: " backup_pass; echo
    if [[ -z "$backup_pass" ]]; then
        print_error "Backup password cannot be empty."
        continue
    fi
    if [[ ${#backup_pass} -lt 8 ]]; then
        print_warn "Backup password is shorter than 8 characters. Use a stronger one."
    fi
    read -rsp "Confirm backup encryption password: " backup_pass2; echo
    [[ "$backup_pass" == "$backup_pass2" ]] && break
    print_error "Passwords do not match. Try again."
done
printf '%s' "$backup_pass" > /etc/xray/backup.pass
chmod 600 /etc/xray/backup.pass
unset root_pass root_pass2 backup_pass backup_pass2
print_success "Backup password saved to /etc/xray/backup.pass (chmod 600)."
sleep 1

print_info "Updating system repositories..."
dnf install epel-release -y >/dev/null 2>&1
dnf makecache >/dev/null 2>&1

print_info "Installing core dependencies..."
dnf install wget curl openssl sudo binutils coreutils gnupg2 bc vnstat htop lsof jq sqlite tar gzip python3 ruby rubygems -y >/dev/null 2>&1
gem install lolcat >/dev/null 2>&1
# Start the vnStat daemon so its database is created (the menu reads bandwidth
# via vnstat; without the daemon it errors "Failed to open database").
systemctl enable vnstat --now >/dev/null 2>&1
systemctl restart vnstat >/dev/null 2>&1
print_success "Core packages installed."

# Fix DNS
print_info "Optimizing DNS resolution..."
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
print_success "DNS configured."

# Fix Port OpenSSH & Permit Root Login
print_info "Configuring SSH Access..."
cd /etc/ssh
sed -i 's/#Port 22/Port 22/g' sshd_config
sed -i 's/#PermitRootLogin.*/PermitRootLogin yes/g' sshd_config
sed -i 's/#PasswordAuthentication.*/PasswordAuthentication yes/g' sshd_config
sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' sshd_config
grep -q "Port 3303" sshd_config || echo -e "Port 3303" >> sshd_config
cd
systemctl daemon-reload
systemctl restart sshd
print_success "SSH Hardening complete (Port 22, 3303)."

# Register the nologin shell so PAM (pam_shells) accepts tunneling accounts.
# Without this, SSH/WS logins fail with "incorrect username or password"
# even when credentials are correct.
print_info "Registering nologin shell in /etc/shells..."
touch /etc/shells
for s in /usr/sbin/nologin /sbin/nologin /bin/false; do
    [[ -e "$s" ]] && { grep -qxF "$s" /etc/shells || echo "$s" >> /etc/shells; }
done
print_success "nologin shell registered."

# Ensure rsyslog writes authpriv (SSH/Dropbear logins) to /var/log/secure.
# Rocky Linux 9 minimal ships journald-only; without rsyslog the IP-limit and
# login-checker scripts (which read /var/log/secure) and the ssh-ws auth-log
# monitor get no data. Dropbear logs via syslog (authpriv) once -E is dropped.
print_info "Configuring rsyslog for /var/log/secure..."
dnf install rsyslog -y >/dev/null 2>&1
if ! grep -rqs 'authpriv\.\*' /etc/rsyslog.conf /etc/rsyslog.d/ 2>/dev/null; then
    echo 'authpriv.*    /var/log/secure' > /etc/rsyslog.d/00-autoscript-secure.conf
fi
systemctl enable rsyslog --now >/dev/null 2>&1
systemctl restart rsyslog >/dev/null 2>&1
print_success "rsyslog active (authpriv -> /var/log/secure)."

# Make A Directory
print_info "Preparing system directories..."
mkdir -p /etc/xray/limit/ip/{ssh,vless,trojan,vmess}
mkdir -p /etc/xray/limit/quota/{vless,trojan,vmess}
mkdir -p /etc/xray/limit/database/{ssh,vless,trojan,vmess}
mkdir -p /etc/xray/usage/quota/{vless,trojan,vmess}
mkdir -p /etc/xray/recovery/{ssh,vless,trojan,vmess}
print_success "Directories created."

# Copy Menu
REPO_OWNER="risqinf"
REPO_NAME="autoscript"
REPO_BRANCH="main"
REPO_TARBALL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"

menu_install_logic() {
    print_info "Downloading management menu..."
    dnf install tar gzip -y >/dev/null 2>&1

    local tmpdir
    tmpdir=$(mktemp -d)
    wget -qO "$tmpdir/repo.tar.gz" "$REPO_TARBALL"
    tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir" >/dev/null 2>&1

    local srcdir="$tmpdir/${REPO_NAME}-${REPO_BRANCH}"

    # Install shared libraries into /usr/local/sbin/lib (sourced, not commands).
    mkdir -p /usr/local/sbin/lib
    if [[ -d "$srcdir/scripts/lib" ]]; then
        install -m 0644 "$srcdir/scripts/lib/"*.sh /usr/local/sbin/lib/ 2>/dev/null
    fi

    # Install command scripts (strip .sh) into /usr/local/sbin so they are
    # callable by bare name. Exclude api/ and lib/.
    mkdir -p /usr/local/sbin/api
    find "$srcdir/scripts" -maxdepth 2 -type f -name '*.sh' \
         ! -path '*/api/*' ! -path '*/lib/*' | while read -r file; do
        name=$(basename "$file" .sh)
        install -m 0755 "$file" "/usr/local/sbin/$name"
    done

    # Install API command scripts (strip .sh) into /usr/local/sbin/api
    find "$srcdir/scripts/api" -maxdepth 1 -type f -name '*.sh' | while read -r file; do
        name=$(basename "$file" .sh)
        install -m 0755 "$file" "/usr/local/sbin/api/$name"
    done

    # Install the uninstaller as a callable command.
    [[ -f "$srcdir/uninstall.sh" ]] && install -m 0755 "$srcdir/uninstall.sh" /usr/local/sbin/uninstall

    rm -rf "$tmpdir"
    print_success "Menu scripts and libraries integrated."
}

if [[ -f "/usr/local/sbin/menu" ]]; then
    print_warn "Menu scripts already exist."
    echo -e "1) Skip\n2) Update Menu"
    read -p "Select [1-2]: " menu_choice
    [[ "$menu_choice" == "2" ]] && menu_install_logic
else
    menu_install_logic
fi

# Initialize SQLite database (single source of truth) and migrate any legacy data.
print_info "Initializing account database (SQLite)..."
if [[ -f /usr/local/sbin/lib/db.sh ]]; then
    . /usr/local/sbin/lib/db.sh
    db_init
    # Import legacy .txt accounts if present (idempotent).
    if [[ -d /etc/xray/database ]] && [[ -x /usr/local/sbin/db-migrate ]]; then
        /usr/local/sbin/db-migrate >/dev/null 2>&1 || true
    fi
    print_success "Database initialized at /etc/xray/xray.db."
else
    print_error "Database library missing; menu may not function."
fi

# Ini firewall
print_info "Hardening Firewall (firewalld - strict allowlist)..."
dnf install firewalld -y >/dev/null 2>&1
systemctl enable firewalld --now >/dev/null 2>&1

# Ensure the default zone denies anything not explicitly allowed.
firewall-cmd --set-default-zone=public >/dev/null 2>&1
firewall-cmd --permanent --zone=public --set-target=default >/dev/null 2>&1

# Remove any previously-opened wide ranges (idempotent cleanup on re-run).
firewall-cmd --permanent --zone=public --remove-port=1-65535/tcp >/dev/null 2>&1
firewall-cmd --permanent --zone=public --remove-port=1-65535/udp >/dev/null 2>&1

# --- Allowlist: only the ports the stack actually uses ---
# SSH management
firewall-cmd --permanent --zone=public --add-port=22/tcp   >/dev/null 2>&1   # OpenSSH
firewall-cmd --permanent --zone=public --add-port=3303/tcp >/dev/null 2>&1   # OpenSSH (alt)
firewall-cmd --permanent --zone=public --add-port=109/tcp  >/dev/null 2>&1   # Dropbear
# Web / proxy entrypoints (HAProxy -> Nginx -> Xray)
firewall-cmd --permanent --zone=public --add-port=80/tcp   >/dev/null 2>&1   # HTTP
firewall-cmd --permanent --zone=public --add-port=443/tcp  >/dev/null 2>&1   # HTTPS/TLS
# BadVPN UDPGW
firewall-cmd --permanent --zone=public --add-port=7300/udp >/dev/null 2>&1
# OpenVPN
firewall-cmd --permanent --zone=public --add-port=1194/tcp >/dev/null 2>&1   # OpenVPN TCP

firewall-cmd --reload >/dev/null 2>&1
print_success "Firewall locked down (allowlist only)."
print_info "Internal services (Xray API 10085, WebAPI 9000, nginx 81) remain bound to 127.0.0.1."

# Enterprise Sysctl Tuning (RAM/CPU aware)
print_info "Applying network tuning for ${TIER} tier (${RAM_MB} MB RAM, ${CPU_CORES} CPU)..."
cat > /etc/sysctl.conf <<EOF
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = ${TCP_RMEM_MAX}
net.core.wmem_max = ${TCP_WMEM_MAX}
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_rmem = 4096 87380 ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${TCP_WMEM_MAX}
net.ipv4.tcp_low_latency = 1
net.ipv4.tcp_max_syn_backlog = 8192
fs.file-max = ${FILE_MAX}
EOF
sysctl -p >/dev/null 2>&1
print_success "Network stack optimized (buffers: $((NET_BUF/1048576)) MB, file-max: ${FILE_MAX})."

# Set Data Domain Server
print_header
echo -e "${LIGHT}Step 2: Server Identification${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
while true; do
    read -p "Input Domain Name: " domain
    if [[ -n "$domain" ]]; then break; else print_error "Domain cannot be empty."; fi
done
echo -e "$domain" > /etc/xray/domain
print_success "Domain set to: $domain"
sleep 1

# Install Dropbear 2019 on EL9
dropbear_install_logic() {
    print_info "Compiling Dropbear 2019.78 for Rocky Linux 9..."
    dnf groupinstall "Development Tools" -y >/dev/null 2>&1
    dnf install zlib-devel wget bzip2 -y >/dev/null 2>&1
    cd /usr/local/src
    wget -q --no-check-certificate https://matt.ucc.asn.au/dropbear/releases/dropbear-2019.78.tar.bz2 || \
    wget -q --no-check-certificate https://dropbear.nl/mirror/releases/dropbear-2019.78.tar.bz2
    tar xjf dropbear-2019.78.tar.bz2 >/dev/null 2>&1
    cd dropbear-2019.78
    ./configure --prefix=/usr --sysconfdir=/etc/dropbear >/dev/null 2>&1
    make -j$(nproc) >/dev/null 2>&1
    make install >/dev/null 2>&1
    cd ..
    rm -fr dropbear*

    cat >/etc/systemd/system/dropbear.service <<'EOF'
[Unit]
Description=Dropbear SSH Server
After=network.target rsyslog.service

[Service]
Type=simple
# No -E: log via syslog (authpriv) so logins reach /var/log/secure.
# -F keeps it in the foreground for systemd Type=simple.
ExecStart=/usr/sbin/dropbear -F -p 109 -b /etc/issue.net -r /etc/dropbear/dropbear_rsa_host_key -W 65536
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    mkdir -p /etc/dropbear
    [ -f /etc/dropbear/dropbear_rsa_host_key ] || dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
    echo -e "Enterprise VPN Server" > /etc/issue.net
    systemctl daemon-reload
    systemctl enable dropbear --now >/dev/null 2>&1
    check_service dropbear
    print_success "Dropbear installed and running on port 109."
}

print_header
echo -e "${LIGHT}Step 3: Component Installation${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

if systemctl is-active dropbear &>/dev/null; then
    print_success "Dropbear is already running."
else
    dropbear_install_logic
fi
clear
cd /root
rm -fr dropbear*

# Install SSH-over-WebSocket proxy: GO-TUNNEL PRO (risqinf/websocket-proxy)
# Static Go binary (CGO_ENABLED=0) — runs natively on Rocky Linux 9.
# Tuned for EL9: auth log = /var/log/secure (not Debian's /var/log/auth.log),
# runs as root (EL9 has no 'adm' group on /var/log/secure).
SSHWS_VERSION="v1.3.0"
sshws_install_logic() {
    print_info "Installing SSH-WebSocket proxy (GO-TUNNEL PRO ${SSHWS_VERSION})..."

    # Detect architecture -> release asset suffix.
    local arch asset
    case "$(uname -m)" in
        x86_64)  arch="linux-amd64" ;;
        aarch64) arch="linux-arm64" ;;
        armv7l)  arch="linux-armv7" ;;
        *) print_error "Unsupported architecture: $(uname -m)"; return 1 ;;
    esac
    asset="ssh-ws-${SSHWS_VERSION}-${arch}.tar.gz"

    local base="https://github.com/risqinf/websocket-proxy/releases/download/${SSHWS_VERSION}"
    local tmp; tmp="$(mktemp -d)"

    if ! wget -qO "${tmp}/ssh-ws.tar.gz" "${base}/${asset}"; then
        print_error "Failed to download ${asset}."
        rm -rf "$tmp"; return 1
    fi

    # Verify checksum against the release checksums.txt (best effort).
    if wget -qO "${tmp}/checksums.txt" "${base}/checksums.txt"; then
        local want got
        want=$(grep -E "  ?${asset}\$" "${tmp}/checksums.txt" | awk '{print $1}')
        got=$(sha256sum "${tmp}/ssh-ws.tar.gz" | awk '{print $1}')
        if [[ -n "$want" && "$want" != "$got" ]]; then
            print_error "Checksum mismatch for ${asset}. Aborting ssh-ws install."
            rm -rf "$tmp"; return 1
        fi
        [[ -n "$want" ]] && print_success "ssh-ws checksum verified."
    fi

    tar -xzf "${tmp}/ssh-ws.tar.gz" -C "$tmp" >/dev/null 2>&1
    # The archive contains a binary named like ssh-ws-<ver>-<arch>
    # (plus a .sha256 sidecar we must not pick).
    local bin
    bin=$(find "$tmp" -maxdepth 1 -type f -name 'ssh-ws-*' \
          ! -name '*.tar.gz' ! -name '*.sha256' | head -1)
    if [[ -z "$bin" ]]; then
        # Fallback: some archives may use a plain 'ssh-ws' name.
        bin=$(find "$tmp" -maxdepth 1 -type f -name 'ssh-ws' | head -1)
    fi
    if [[ -z "$bin" ]]; then
        print_error "ssh-ws binary not found in archive."
        rm -rf "$tmp"; return 1
    fi
    install -m 0755 "$bin" /usr/local/bin/ssh-ws
    rm -rf "$tmp"

    # Generate a random per-connection password (optional; clients send X-Pass).
    # Leave auth disabled by default so existing client configs keep working;
    # the proxy is only reachable via nginx/HAProxy on the public TLS port.
    cat > /etc/systemd/system/ssh-ws.service <<'EOF'
[Unit]
Description=GO-TUNNEL PRO SSH WebSocket Proxy
After=network.target dropbear.service
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ssh-ws -b 0.0.0.0 -p 8888 -t 127.0.0.1:109 \
  -l /var/log/ssh-ws.log --auth-log /var/log/secure --api-port 8081
Restart=always
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable ssh-ws --now >/dev/null 2>&1
    check_service ssh-ws
    print_success "SSH-WebSocket proxy running on port 8888 (-> SSH 109); UDPGW on 7300; API on 127.0.0.1:8081."
}

if systemctl is-active ssh-ws &>/dev/null; then
    print_success "SSH-WebSocket proxy already running."
else
    sshws_install_logic
fi

# Install Xray
xray_install_logic() {
    print_info "Synchronizing Xray-core release 25.10.15..."
    mkdir -p /usr/local/share/xray
    wget -q -O /usr/local/share/xray/geosite.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    wget -q -O /usr/local/share/xray/geoip.dat "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
    chmod +x /usr/local/share/xray/*
    
    # Write Structured Xray Configuration
    print_info "Generating secure Xray configuration..."
    uuid=$(cat /proc/sys/kernel/random/uuid)
    cat > /etc/xray/config.json <<EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "loglevel": "info"
  },
  "api": {
    "tag": "api",
    "services": [
      "StatsService"
    ]
  },
  "stats": {},
  "policy": {
    "levels": {
      "0": {
        "statsUserDownlink": true,
        "statsUserUplink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  },
  "inbounds": [
    {
      "tag": "api",
      "listen": "127.0.0.1",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": {
        "address": "127.0.0.1"
      }
    },
    {
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "port": 1,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vless"
        }
      }
    },
    {
      "tag": "trojan-ws",
      "listen": "127.0.0.1",
      "port": 2,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${uuid}"
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/trojan"
        }
      }
    },
    {
      "tag": "vmess-ws",
      "listen": "127.0.0.1",
      "port": 3,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "blocked"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "protocol": [
          "bittorrent"
        ]
      },
      {
        "type": "field",
        "outboundTag": "blocked",
        "ip": [
          "0.0.0.0/8",
          "10.0.0.0/8",
          "100.64.0.0/10",
          "169.254.0.0/16",
          "172.16.0.0/12",
          "192.0.0.0/24",
          "192.0.2.0/24",
          "192.168.0.0/16",
          "198.18.0.0/15",
          "198.51.100.0/24",
          "203.0.113.0/24",
          "::1/128",
          "fc00::/7",
          "fe80::/10"
        ]
      }
    ]
  }
}
EOF

    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u nobody --version 25.10.15 >/dev/null 2>&1
    
    mkdir -p /var/log/xray
    touch /var/log/xray/{access,error}.log
    chown -R root:root /var/log/xray
    chmod 644 /var/log/xray/*.log

    # Remove any service unit the XTLS installer may have created, then write
    # our own (xray run -config, with reload + resource limits).
    rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service 2>/dev/null
    rm -rf /etc/systemd/system/xray.service.d 2>/dev/null

    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=5s

# Resource Limits
LimitNOFILE=1048576
LimitNPROC=1048576
LimitCORE=infinity
TasksMax=infinity

# Network Tuning
LimitMEMLOCK=infinity

# Process Priority
Nice=-10

# Security
PrivateTmp=true
ProtectSystem=false
ProtectHome=false

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray --now >/dev/null 2>&1
    systemctl restart xray >/dev/null 2>&1
    check_service xray
    print_success "Xray Core initialized."
}

if [[ -f "/etc/xray/config.json" ]]; then
    print_warn "Xray core is already configured."
    echo -e "1) Skip\n2) Reinstall & Regenerate UUID"
    read -p "Select [1-2]: " xray_choice
    [[ "$xray_choice" == "2" ]] && xray_install_logic
else
    xray_install_logic
fi

# SELinux: permit the reverse-proxy chain (nginx/httpd) to open local network
# connections to the Xray/ssh-ws/dropbear upstreams. Without this, on an
# Enforcing system nginx fails with "connect() ... (13: Permission denied)"
# when proxying to 127.0.0.1:1/2/3.
print_info "Configuring SELinux booleans for the proxy stack..."
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    dnf install -y policycoreutils >/dev/null 2>&1 || true
    setsebool -P httpd_can_network_connect 1    2>/dev/null
    setsebool -P httpd_can_network_connect_db 1 2>/dev/null
    setsebool -P httpd_can_network_relay 1      2>/dev/null
    print_success "SELinux booleans applied (httpd network connect enabled)."
else
    print_info "SELinux disabled or not present; skipping booleans."
fi

# Nginx & Certificate Setup
print_info "Obtaining SSL Certificates (Let's Encrypt)..."
dnf install socat lsof certbot -y >/dev/null 2>&1
systemctl stop httpd nginx >/dev/null 2>&1
certbot certonly --standalone --preferred-challenges http --agree-tos --email www@${domain} -d $domain --non-interactive

# Verify the certificate was actually issued before continuing.
if [[ -f /etc/letsencrypt/live/$domain/fullchain.pem && -f /etc/letsencrypt/live/$domain/privkey.pem ]]; then
    cp /etc/letsencrypt/live/$domain/fullchain.pem /etc/xray/xray.crt
    cp /etc/letsencrypt/live/$domain/privkey.pem /etc/xray/xray.key
    chmod 644 /etc/xray/xray.crt
    chmod 600 /etc/xray/xray.key
    print_success "Certificates issued."
else
    print_error "Certificate issuance failed for ${domain}."
    print_error "Check that the domain points to this server's IP and port 80 is reachable."
    print_warn "Aborting installation. Re-run after fixing DNS/port 80."
    exit 1
fi

# Setup Nginx
nginx_install_logic() {
    print_info "Configuring Nginx Enterprise Node..."
    dnf install nginx -y >/dev/null 2>&1
    
    cat > /etc/nginx/nginx.conf <<EOF
user nginx;
worker_processes auto;
worker_cpu_affinity auto;
worker_rlimit_nofile ${NGX_RLIMIT};

events {
    worker_connections ${NGX_CONN};
    multi_accept on;
    use epoll;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 300;
    keepalive_requests 10000;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    access_log off;
    error_log /var/log/nginx/error.log crit;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    include /etc/nginx/risqinf.conf;
}
EOF

    cat > /etc/nginx/risqinf.conf <<EOF
upstream vmess_ws {
    server 127.0.0.1:3;
    keepalive 32;
}

upstream ssh_ws {
    server 127.0.0.1:8888;
    keepalive 32;
}

upstream vless_ws {
    server 127.0.0.1:1;
    keepalive 32;
}

upstream trojan_ws {
    server 127.0.0.1:2;
    keepalive 32;
}

# Proper Connection header for WebSocket upgrades.
map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ''      close;
}

# Root-path discriminator. A genuine WebSocket handshake (vmess/v2ray client)
# always carries a "Sec-WebSocket-Key" header. SSH-WS injector payloads send a
# bare "GET / HTTP/1.1" with only an Upgrade line and no Sec-WebSocket-Key, so
# they must NOT be sent to the vmess inbound (which answered 400
# "unsupported Sec-WebSocket-Version"). Route by that header instead.
# NOTE: an IP:port literal is used (not the upstream name) because a variable
# in proxy_pass would otherwise require a DNS resolver.
map \$http_sec_websocket_key \$root_upstream {
    default  127.0.0.1:8888;   # no Sec-WebSocket-Key  -> SSH-WS
    "~.+"    127.0.0.1:3;       # has Sec-WebSocket-Key -> VMESS inbound
}

server {
    listen 127.0.0.1:81 default_server proxy_protocol;
    server_name ${domain};

    # Explicit protocol paths. Each uses a static proxy_pass (no variables) so
    # nginx resolves the upstream block directly (a variable in proxy_pass would
    # bypass the upstream and require a DNS resolver).
    location /vless {
        if (\$http_upgrade != "websocket") { return 444; }
        proxy_pass http://vless_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # Explicit /vmess path: silently reject scanners. VMESS clients use "/"
    # (the root-path location below) — not this explicit path.
    location /vmess {
        if (\$http_upgrade != "websocket") { return 444; }
        proxy_pass http://vmess_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    location /trojan {
        if (\$http_upgrade != "websocket") { return 444; }
        proxy_pass http://trojan_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # Explicit SSH-WS path (always forced to the ssh-ws proxy).
    location /ssh {
        if (\$http_upgrade != "websocket") { return 444; }
        proxy_pass http://ssh_ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }

    # OpenVPN client config downloads.
    location /risqinf/ {
        alias /var/www/html/risqinf/;
        autoindex on;
    }

    # Future REST API (server not yet shipped).
    location /api/ {
        proxy_pass http://127.0.0.1:9000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    # VMESS multipath (any other path) OR SSH-WS, decided by the handshake.
    # Any non-protocol path is rewritten to "/" for the vmess inbound.
    location / {
        if (\$http_upgrade != "websocket") { return 444; }
        rewrite ^.*\$ / break;
        proxy_pass http://\$root_upstream;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
    }
}
EOF
    systemctl daemon-reload
    systemctl enable nginx --now >/dev/null 2>&1
    check_service nginx
    print_success "Nginx Enterprise Node optimized."
}

if [[ -f "/etc/nginx/risqinf.conf" ]]; then
    print_warn "Nginx is already configured."
    echo -e "1) Skip\n2) Overwrite"
    read -p "Select [1-2]: " nginx_choice
    [[ "$nginx_choice" == "2" ]] && nginx_install_logic
else
    nginx_install_logic
fi

# Setup HAProxy
haproxy_install_logic() {
    print_info "Configuring HAProxy Enterprise Balancing..."
    dnf install haproxy -y >/dev/null 2>&1
    
    # Generate combined certificate for HAProxy
    mkdir -p /etc/haproxy
    cat /etc/xray/xray.crt /etc/xray/xray.key | tee /etc/haproxy/haproxy.pem > /dev/null
    chmod 600 /etc/haproxy/haproxy.pem

    cat > /etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn ${HA_MAXCONN}
    user haproxy
    group haproxy
    daemon
    tune.ssl.default-dh-param 2048

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 30m
    timeout server 30m

# Plain HTTP on :80 -> nginx (WS over HTTP, ACME, downloads).
frontend http_in
    bind *:80
    mode tcp
    default_backend nginx_http

# TLS on :443. HAProxy terminates TLS (one cert, any SNI), then splits traffic
# by the FIRST decrypted bytes:
#   * starts with an HTTP method  -> WebSocket/HTTP stack (nginx -> xray/ssh-ws)
#   * anything else (raw SSH)      -> Dropbear directly  == SSH "SSL/TLS" / "SNI"
# This lets one 443 port serve BOTH SSH-WebSocket AND SSH-SSL/SNI direct tunnels
# alongside VMESS/VLESS/Trojan.
frontend tls_in
    bind *:443 ssl crt /etc/haproxy/haproxy.pem
    mode tcp
    tcp-request inspect-delay 5s
    # Detect an HTTP request line in the decrypted payload.
    acl is_http req.payload(0,10) -m reg -i ^(GET|POST|HEAD|PUT|OPTIONS|DELETE|PATCH|TRACE|CONNECT)
    # Proceed as soon as the client sends any bytes; otherwise fall through after
    # the inspect-delay (SSH servers greet first, so SSH-SSL may send nothing).
    tcp-request content accept if { req.len gt 0 }
    use_backend nginx_http if is_http
    # Default: treat as raw SSH inside TLS -> Dropbear (SSH-SSL / SNI tunneling).
    default_backend ssh_direct

backend nginx_http
    mode tcp
    server nginx_node 127.0.0.1:81 send-proxy check

backend ssh_direct
    mode tcp
    # No send-proxy: Dropbear does not speak the PROXY protocol.
    server dropbear_node 127.0.0.1:109 check
EOF
    systemctl enable haproxy --now >/dev/null 2>&1
    check_service haproxy
    print_success "HAProxy Balancing complete."
}

if [[ -f "/etc/haproxy/haproxy.cfg" ]]; then
    print_warn "HAProxy is already configured."
    echo -e "1) Skip\n2) Overwrite"
    read -p "Select [1-2]: " haproxy_choice
    [[ "$haproxy_choice" == "2" ]] && haproxy_install_logic
else
    haproxy_install_logic
fi

# ---- Scheduled maintenance via systemd timers (NO cron) ----
# All periodic jobs that used to live in /etc/crontab now run as systemd
# timer+oneshot units. This removes the cron dependency entirely and gives
# every job a managed unit that shows up in the Service Status menu.

# Auto-expire all protocols (SSH/VLESS/VMESS/Trojan) once a minute.
cat > /etc/systemd/system/autoexpire.service <<'EOF'
[Unit]
Description=Auto-expire accounts (all protocols)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/expire-all
EOF

cat > /etc/systemd/system/autoexpire.timer <<'EOF'
[Unit]
Description=Run account auto-expire every minute

[Timer]
OnBootSec=60
OnUnitActiveSec=60
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# SSH IP-limit enforcement every 2 minutes.
cat > /etc/systemd/system/limit-ip-ssh.service <<'EOF'
[Unit]
Description=SSH IP-limit enforcement
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/limit-ip-ssh
EOF

cat > /etc/systemd/system/limit-ip-ssh.timer <<'EOF'
[Unit]
Description=Run SSH IP-limit enforcement every 2 minutes

[Timer]
OnBootSec=90
OnUnitActiveSec=120
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Hourly backup.
cat > /etc/systemd/system/backup.service <<'EOF'
[Unit]
Description=Account/database backup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup
EOF

cat > /etc/systemd/system/backup.timer <<'EOF'
[Unit]
Description=Run backup hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Daily log maintenance.
cat > /etc/systemd/system/fixlog.service <<'EOF'
[Unit]
Description=Log maintenance (cap sizes, keep recent monitor data)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fixlog
EOF

cat > /etc/systemd/system/fixlog.timer <<'EOF'
[Unit]
Description=Run log maintenance daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now autoexpire.timer limit-ip-ssh.timer backup.timer fixlog.timer

# Install Package Lain
curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | sudo bash
sudo dnf install speedtest -y

# Setup Limit IP & Quota Services
cat > /etc/systemd/system/quota.service <<EOF
[Unit]
Description=Vless Quota Looping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-quota-vless
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/limit-ip-vless.service <<EOF
[Unit]
Description=Vless Limit IP Looping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-ip-vless
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/quota-trojan.service <<EOF
[Unit]
Description=Trojan Quota Looping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-quota-trojan
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/limit-ip-trojan.service <<EOF
[Unit]
Description=Trojan Limit IP Looping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-ip-trojan
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/quota-vmess.service <<EOF
[Unit]
Description=Vmess Quota Looping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-quota-vmess
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/limit-ip-vmess.service <<EOF
[Unit]
Description=Vmess Limit IP Looping
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-ip-vmess
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable quota limit-ip-vless --now
systemctl enable quota-trojan limit-ip-trojan --now
systemctl enable quota-vmess limit-ip-vmess --now
for svc in quota limit-ip-vless quota-trojan limit-ip-trojan quota-vmess limit-ip-vmess; do
    check_service "$svc" || print_warn "Looping service '$svc' not active (will retry via Restart=on-failure)."
done

# Api Server
# NOTE: The RESTful API server is being rebuilt from scratch and is not yet
# available. This sets up the directory and systemd unit, but the server
# binary is intentionally not installed or enabled here.
api_server_install_logic() {
    mkdir -p /etc/api
    mkdir -p /usr/local/sbin/api

    # Configure WebAPI Server Service (disabled until the server is rebuilt)
    cat > /etc/systemd/system/server.service <<EOF
[Unit]
Description=WebAPI Server Proxy by risqinf
Documentation=https://github.com/risqinf/autoscript
After=syslog.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/sbin/api
ExecStart=/usr/local/bin/server
Restart=on-failure
RestartPreventExitStatus=23
RestartSec=5
TimeoutStopSec=30
KillSignal=SIGTERM

# Performance Tuning
LimitNPROC=10000
LimitNOFILE=1000000

# Security & Sandboxing
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ReadWritePaths=/var/log /usr/local/sbin/api /etc/api /etc/xray /tmp /var/tmp

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    print_warn "WebAPI server binary not installed (to be rebuilt). Service unit prepared but not started."
}

if [[ -f "/usr/local/bin/server" ]]; then
    echo -e "\e[32m[SKIP]\e[0m WebAPI Server is already installed."
    echo -e "1) Skip"
    echo -e "2) Reinstall"
    read -p "Select [1-2]: " api_choice
    [[ "$api_choice" == "2" ]] && api_server_install_logic
else
    api_server_install_logic
fi

clear
echo -e "clear ; menu" > /root/.profile

# Dynamic Swap Management (KVM Optimized)
swap_install_logic() {
    echo -e "———————————————————————————————————————————————————————"
    echo -e "            CONFIGURING DYNAMIC SWAP (RAM-aware)"
    echo -e "———————————————————————————————————————————————————————"

    # Swap sizing is driven by RAM (most needed on low-RAM VPS), then capped
    # by available disk. Applies to all virt types (not just KVM).
    FREE_DISK=$(df -k / | awk 'NR==2 {print $4}')   # KB free on /
    # Target swap by RAM tier.
    if   (( RAM_MB <= 1280 )); then SWAP_SIZE_GB=2     # ~1GB RAM -> 2GB swap
    elif (( RAM_MB <= 2560 )); then SWAP_SIZE_GB=2     # ~2GB RAM -> 2GB swap
    elif (( RAM_MB <= 5120 )); then SWAP_SIZE_GB=4     # ~4GB RAM -> 4GB swap
    else                            SWAP_SIZE_GB=4     # >4GB RAM -> 4GB swap (plenty)
    fi
    # Cap by disk: need swap size + 5GB headroom free.
    NEED_KB=$(( (SWAP_SIZE_GB * 1024 * 1024) + (5 * 1024 * 1024) ))
    while (( SWAP_SIZE_GB > 0 )) && (( FREE_DISK < NEED_KB )); do
        SWAP_SIZE_GB=$(( SWAP_SIZE_GB - 1 ))
        NEED_KB=$(( (SWAP_SIZE_GB * 1024 * 1024) + (5 * 1024 * 1024) ))
    done

    if true; then
        if [ "$SWAP_SIZE_GB" -gt 0 ]; then
            echo -e "\e[32m[INFO]\e[0m RAM ${RAM_MB} MB -> creating ${SWAP_SIZE_GB}GB swapfile..."
            
            # Cleanup Old Swap
            swapoff -a >/dev/null 2>&1
            sed -i '/swapfile/d' /etc/fstab >/dev/null 2>&1
            rm -f /swapfile >/dev/null 2>&1


            # Create Swapfile
            if command -v fallocate >/dev/null 2>&1; then
                fallocate -l ${SWAP_SIZE_GB}G /swapfile
            else
                dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024))
            fi

            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1
            swapon /swapfile >/dev/null 2>&1
            echo "/swapfile none swap defaults 0 0" >> /etc/fstab

            # Swappiness: lean on swap more on low-RAM boxes, less on big ones.
            if (( RAM_MB <= 1280 )); then SWAPPINESS=60; else SWAPPINESS=15; fi
            sysctl -w vm.swappiness=${SWAPPINESS} >/dev/null 2>&1
            echo "vm.swappiness=${SWAPPINESS}" >> /etc/sysctl.conf

            echo -e "\e[32m[OK]\e[0m ${SWAP_SIZE_GB}GB swap active (swappiness=${SWAPPINESS})."
        else
            echo -e "\e[31m[WARN]\e[0m Not enough free disk for a swapfile; skipped."
        fi
    fi
    echo -e "———————————————————————————————————————————————————————"
}

if [[ -f "/swapfile" ]]; then
    echo -e "\e[32m[SKIP]\e[0m Swapfile is already configured."
else
    swap_install_logic
fi

# Backup Setup (Google Drive via rclone)
# NOTE: No credentials are shipped. Configure your own remote interactively.
curl https://rclone.org/install.sh | bash
if [[ ! -f /root/.config/rclone/rclone.conf ]]; then
    print_warn "rclone is installed but no remote is configured."
    print_info "Run 'rclone config' to add your Google Drive remote (name it 'risqinf')."
fi
cd /root

# Setup OpenVPN
WEB_DIR="/var/www/html/risqinf/openvpn"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
ovpn_install_logic() {
    echo "=================================================="
    echo "INSTALLING OPENVPN..."
    echo "=================================================="
    WEB_DIR="/var/www/html/risqinf/openvpn"
    EASYRSA_DIR="/etc/openvpn/easy-rsa"
    dnf install -y openvpn easy-rsa iptables-services
    mkdir -p $WEB_DIR
    mkdir -p $EASYRSA_DIR
    mkdir -p /etc/openvpn/server
    cp -r /usr/share/easy-rsa/3/* $EASYRSA_DIR/
    cd $EASYRSA_DIR

    # Non-interactive PKI: batch mode + pre-filled fields so certificate
    # credentials are generated and confirmed automatically (no prompts).
    export EASYRSA_BATCH=1
    export EASYRSA_REQ_CN="AutoscriptCA"
    export EASYRSA_REQ_COUNTRY="ID"
    export EASYRSA_REQ_PROVINCE="Jakarta"
    export EASYRSA_REQ_CITY="Jakarta"
    export EASYRSA_REQ_ORG="risqinf"
    export EASYRSA_REQ_EMAIL="admin@${domain}"
    export EASYRSA_REQ_OU="VPN"
    export EASYRSA_ALGO="rsa"
    export EASYRSA_KEY_SIZE=2048

    ./easyrsa init-pki
    ./easyrsa --batch build-ca nopass
    ./easyrsa --batch gen-req server nopass
    ./easyrsa --batch sign-req server server
    ./easyrsa gen-dh
    openvpn --genkey secret ta.key

    cp pki/ca.crt pki/issued/server.crt pki/private/server.key pki/dh.pem ta.key /etc/openvpn/server/

    # Verify every credential exists and is non-empty before continuing.
    ovpn_ok=1
    for f in ca.crt server.crt server.key dh.pem ta.key; do
        if [[ ! -s "/etc/openvpn/server/$f" ]]; then
            print_error "OpenVPN credential missing/empty: $f"
            ovpn_ok=0
        fi
    done
    if [[ $ovpn_ok -eq 1 ]]; then
        print_success "OpenVPN certificates generated and verified (CA, server cert/key, DH, TA)."
    else
        print_error "OpenVPN certificate generation failed; client profiles may not work."
    fi
    PLUGIN_PAM="/usr/lib64/openvpn/plugins/openvpn-plugin-auth-pam.so"

    # TCP Server Config
    cat > /etc/openvpn/server/server-tcp-1194.conf <<EOF
port 1194
proto tcp
dev tun
ca ca.crt
cert server.crt
key server.key
dh dh.pem
tls-auth ta.key 0
topology subnet
server 10.9.0.0 255.255.255.0
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 1.1.1.1"
socket-flags TCP_NODELAY
push "socket-flags TCP_NODELAY"
keepalive 10 120
comp-lzo no
push "comp-lzo no"
cipher AES-128-GCM
data-ciphers AES-128-GCM:AES-256-GCM
auth SHA256
plugin $PLUGIN_PAM login
verify-client-cert none
username-as-common-name
persist-key
persist-tun
status openvpn-status-tcp.log
verb 3
EOF

    CA_DATA=$(cat /etc/openvpn/server/ca.crt)
    TA_DATA=$(cat /etc/openvpn/server/ta.key)

    # Client OVPN Generation (TCP only)
    cat > $WEB_DIR/tcp.ovpn <<EOF
client
dev tun
proto tcp
remote $domain 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
key-direction 1
setenv CLIENT_CERT 0
setenv FRIENDLY_NAME "OpenVPN TCP"
socket-flags TCP_NODELAY
cipher AES-128-GCM
auth SHA256
auth-user-pass
comp-lzo no
verb 3
<ca>
$CA_DATA
</ca>
<tls-auth>
$TA_DATA
</tls-auth>
EOF

    # Routing & Firewall
    echo 1 > /proc/sys/net/ipv4/ip_forward
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
    sysctl -p
    firewall-cmd --zone=public --add-port=1194/tcp --permanent
    firewall-cmd --add-masquerade --permanent
    firewall-cmd --reload

    systemctl enable openvpn-server@server-tcp-1194
    systemctl restart openvpn-server@server-tcp-1194
    check_service "openvpn-server@server-tcp-1194" || print_warn "OpenVPN TCP not active."
}

if [[ -f "/etc/openvpn/server/server-tcp-1194.conf" ]]; then
    # OpenVPN configuration is complex, we just check for file existence
    # but we can check if the domain matches in the generated files.
    if grep -q "$domain" "$WEB_DIR/tcp.ovpn" 2>/dev/null; then
        echo -e "\e[32m[SKIP]\e[0m OpenVPN is already installed and matches current domain."
    else
        ovpn_install_logic
    fi
else
    ovpn_install_logic
fi

clear
# Notification
echo ""
echo -e "\e[0;42;30m              INSTALLATION COMPLETE                         \e[0m"
echo ""
echo -e " Run 'menu' to open the management panel."
echo -e " Tip: configure Telegram (System -> Telegram Setup) for notifications."
echo ""

# Self-delete: remove the installer (and any leftover *.sh in this dir) so the
# server is left clean once setup finishes.
SELF="$(readlink -f "$0" 2>/dev/null)"
cd /root 2>/dev/null
[[ -n "$SELF" && -f "$SELF" ]] && rm -f "$SELF" 2>/dev/null
rm -f /root/install.sh /root/uninstall.sh 2>/dev/null
exit 0
