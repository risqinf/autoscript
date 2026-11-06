#!/bin/bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: AutoScript VPN & Tunneling Management System
# Supported OS: Rocky Linux 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10
# Version: 5.6.1
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
AS_VERSION="5.6.1"
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
  echo -e "${PURPLE}           ENTERPRISE VPN AUTOSCRIPT INSTALLER              ${NC}"
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
  for ((i = 0; i < width; i++)); do echo -ne " "; done
  echo -ne "] 0%"
  for ((i = 0; i <= width; i++)); do
    local per=$((i * 100 / width))
    echo -ne "\r  Progress: ["
    for ((j = 0; j < i; j++)); do echo -ne "■"; done
    for ((j = i; j < width; j++)); do echo -ne " "; done
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
  CPU_CORES=$(nproc 2>/dev/null)
  [[ "$CPU_CORES" =~ ^[0-9]+$ ]] || CPU_CORES=1
  RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null)
  [[ "$RAM_MB" =~ ^[0-9]+$ ]] || RAM_MB=1024

  # Tier by total RAM.
  if ((RAM_MB <= 1280)); then
    TIER="1GB"
    NGX_CONN=4096
    HA_MAXCONN=8192
    NET_BUF=16777216
    XRAY_NOFILE=262144
  elif ((RAM_MB <= 2560)); then
    TIER="2GB"
    NGX_CONN=16384
    HA_MAXCONN=32768
    NET_BUF=33554432
    XRAY_NOFILE=524288
  elif ((RAM_MB <= 5120)); then
    TIER="4GB"
    NGX_CONN=65535
    HA_MAXCONN=100000
    NET_BUF=67108864
    XRAY_NOFILE=1000000
  else
    TIER="8GB+"
    NGX_CONN=131072
    HA_MAXCONN=200000
    NET_BUF=134217728
    XRAY_NOFILE=1000000
  fi

  # nginx: one worker per core; rlimit must cover all connections per worker
  # (cap so cores*conn doesn't exceed the system fd ceiling unreasonably).
  NGX_WORKERS=$CPU_CORES
  NGX_RLIMIT=$((NGX_CONN + 1024))
  ((NGX_RLIMIT < 65535)) && NGX_RLIMIT=65535
  # System-wide fd ceiling for the file-max sysctl.
  FILE_MAX=$(((NGX_CONN * CPU_CORES) + 100000))
  ((FILE_MAX < 262144)) && FILE_MAX=262144

  # TCP buffer auto-tune ceilings scale with the tier.
  TCP_RMEM_MAX=$NET_BUF
  TCP_WMEM_MAX=$NET_BUF
}

# Check if the user is root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: This script must be run as root!${NC}"
  exit 1
fi

# ========================================================
# Enterprise Linux 9 & 10 Multi-Distro Verification & Repo Setup
# Supports: Rocky Linux 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10
# ========================================================
detect_and_verify_el_os() {
  EL_ID="unknown"
  EL_MAJOR="0"
  EL_PRETTY="Unknown Linux"
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    EL_ID="${ID:-unknown}"
    EL_MAJOR="${VERSION_ID%%.*}"
    EL_PRETTY="${PRETTY_NAME:-${NAME:-Linux}}"
  fi

  case "$EL_ID" in
    rocky|rhel|almalinux|ol)
      if [[ "$EL_MAJOR" != "9" && "$EL_MAJOR" != "10" ]]; then
        print_error "Unsupported version: ${EL_PRETTY} (Major: ${EL_MAJOR})."
        print_error "Supported OS: Rocky Linux 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10."
        exit 1
      fi
      ;;
    *)
      if [[ "${FORCE_INSTALL:-0}" != "1" ]]; then
        print_error "Unsupported distribution: ${EL_PRETTY} (ID=${EL_ID})."
        print_error "Supported OS: Rocky Linux 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10."
        exit 1
      fi
      ;;
  esac
}

enable_el_repositories() {
  print_info "Configuring Enterprise Linux ${EL_MAJOR} repositories for ${EL_PRETTY}..."
  dnf install -y dnf-plugins-core curl ca-certificates >/dev/null 2>&1 || true

  case "$EL_ID" in
    rocky|almalinux)
      dnf config-manager --set-enabled crb >/dev/null 2>&1 || \
        dnf config-manager setopt crb.enabled=1 >/dev/null 2>&1 || true
      dnf install -y epel-release >/dev/null 2>&1 || \
        dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJOR}.noarch.rpm" >/dev/null 2>&1 || true
      ;;
    rhel)
      local arch_m; arch_m="$(uname -m)"
      subscription-manager repos --enable "codeready-builder-for-rhel-${EL_MAJOR}-${arch_m}-rpms" >/dev/null 2>&1 || \
        dnf config-manager --set-enabled "codeready-builder-for-rhel-${EL_MAJOR}-*" >/dev/null 2>&1 || \
        dnf config-manager --set-enabled "rhui-codeready-builder-for-rhel-${EL_MAJOR}-*" >/dev/null 2>&1 || \
        dnf config-manager setopt "codeready-builder-for-rhel-${EL_MAJOR}-${arch_m}-rpms.enabled=1" >/dev/null 2>&1 || true
      dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJOR}.noarch.rpm" >/dev/null 2>&1 || true
      ;;
    ol)
      dnf config-manager --set-enabled "ol${EL_MAJOR}_codeready_builder" >/dev/null 2>&1 || \
        dnf config-manager setopt "ol${EL_MAJOR}_codeready_builder.enabled=1" >/dev/null 2>&1 || true
      dnf install -y "oracle-epel-release-el${EL_MAJOR}" >/dev/null 2>&1 || \
        dnf install -y "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${EL_MAJOR}.noarch.rpm" >/dev/null 2>&1 || true
      ;;
  esac

  dnf makecache >/dev/null 2>&1 || true
  print_success "Repositories ready (${EL_PRETTY} - EL${EL_MAJOR})."
}

detect_resources
detect_and_verify_el_os

# Password Root Change
print_header
echo -e "${LIGHT}Preparation: Security Hardening${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
while true; do
  read -rsp "Enter new root password: " root_pass
  echo
  if [[ -z "$root_pass" ]]; then
    print_error "Root password cannot be empty."
    continue
  fi
  if [[ ${#root_pass} -lt 8 ]]; then
    print_warn "Password is shorter than 8 characters. Use a stronger one."
  fi
  read -rsp "Confirm new root password: " root_pass2
  echo
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
  read -rsp "Enter backup encryption password: " backup_pass
  echo
  if [[ -z "$backup_pass" ]]; then
    print_error "Backup password cannot be empty."
    continue
  fi
  if [[ ${#backup_pass} -lt 8 ]]; then
    print_warn "Backup password is shorter than 8 characters. Use a stronger one."
  fi
  read -rsp "Confirm backup encryption password: " backup_pass2
  echo
  [[ "$backup_pass" == "$backup_pass2" ]] && break
  print_error "Passwords do not match. Try again."
done
printf '%s' "$backup_pass" >/etc/xray/backup.pass
chmod 600 /etc/xray/backup.pass
printf 'zip' >/etc/xray/autobackup.type
touch /etc/xray/cloudvault.url
unset root_pass root_pass2 backup_pass backup_pass2
print_success "Backup password saved to /etc/xray/backup.pass (chmod 600)."
sleep 1

enable_el_repositories

print_info "Installing core dependencies..."
dnf install -y wget curl openssl sudo binutils coreutils gnupg2 bc htop lsof jq sqlite tar gzip bzip2 xz unzip python3 util-linux policycoreutils policycoreutils-python-utils >/dev/null 2>&1
dnf install -y vnstat ruby rubygems >/dev/null 2>&1 || true
command -v gem >/dev/null 2>&1 && gem install lolcat >/dev/null 2>&1 || true
if systemctl list-unit-files vnstat.service >/dev/null 2>&1; then
  systemctl enable vnstat --now >/dev/null 2>&1 || true
  systemctl restart vnstat >/dev/null 2>&1 || true
fi
print_success "Core packages installed."

# Fix DNS
print_info "Optimizing DNS resolution..."
echo "nameserver 8.8.8.8" >/etc/resolv.conf
echo "nameserver 1.1.1.1" >>/etc/resolv.conf
print_success "DNS configured."

# Fix Port OpenSSH, SELinux ssh_port_t 3303 & Strict Tunnel Isolation (EL9 & EL10)
print_info "Hardening OpenSSH Access (Port 22, 3303)..."
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]] && command -v semanage >/dev/null 2>&1; then
  semanage port -a -t ssh_port_t -p tcp 3303 >/dev/null 2>&1 || \
    semanage port -m -t ssh_port_t -p tcp 3303 >/dev/null 2>&1 || true
fi
mkdir -p /etc/ssh/sshd_config.d
# On EL9/EL10, /etc/ssh/sshd_config.d/*.conf is evaluated in lexical order and
# first-match wins over cloud-init's 50-cloud-init.conf (PasswordAuthentication no).
cat >/etc/ssh/sshd_config.d/00-autoscript.conf <<'EOF'
# Autoscript v5.6.1 Hardened OpenSSH Configuration (EL9 & EL10)
Port 22
Port 3303
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UseDNS no
LoginGraceTime 60
MaxAuthTries 5
MaxStartups 100:30:200
ClientAliveInterval 60
ClientAliveCountMax 3
X11Forwarding no
AllowAgentForwarding no

Match User *,!root
    X11Forwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    PermitTunnel no
    GatewayPorts no
    PermitTTY no
EOF
chmod 600 /etc/ssh/sshd_config.d/00-autoscript.conf
if [[ -f /etc/ssh/sshd_config ]]; then
  sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/g' /etc/ssh/sshd_config
fi
systemctl daemon-reload >/dev/null 2>&1
systemctl restart sshd >/dev/null 2>&1
print_success "OpenSSH hardened & active on ports 22 and 3303."

# Register the nologin shell so PAM (pam_shells) accepts tunneling accounts.
# Without this, SSH/WS logins fail with "incorrect username or password"
# even when credentials are correct.
print_info "Registering nologin shell in /etc/shells..."
touch /etc/shells
for s in /usr/sbin/nologin /sbin/nologin /bin/false; do
  [[ -e "$s" ]] && { grep -qxF "$s" /etc/shells || echo "$s" >>/etc/shells; }
done
print_success "nologin shell registered."

# Ensure rsyslog writes authpriv (SSH/Dropbear logins) to /var/log/secure.
# Rocky Linux 9 minimal ships journald-only; without rsyslog the IP-limit and
# login-checker scripts (which read /var/log/secure) and the ssh-ws auth-log
# monitor get no data. Dropbear logs via syslog (authpriv) once -E is dropped.
print_info "Configuring rsyslog for /var/log/secure..."
dnf install rsyslog -y >/dev/null 2>&1
if ! grep -rqs 'authpriv\.\*' /etc/rsyslog.conf /etc/rsyslog.d/ 2>/dev/null; then
  echo 'authpriv.*    /var/log/secure' >/etc/rsyslog.d/00-autoscript-secure.conf
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
mkdir -p /etc/xray/recovery/{ssh,vless,trojan,vmess,noobz}
print_success "Directories created."

# Copy Menu
REPO_OWNER="risqinf"
REPO_NAME="autoscript"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_TARBALL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"

menu_install_logic() {
  print_info "Downloading management menu..."
  dnf install tar gzip -y >/dev/null 2>&1

  local tmpdir
  tmpdir=$(mktemp -d)
  wget -qO "$tmpdir/repo.tar.gz" "$REPO_TARBALL"
  tar -xzf "$tmpdir/repo.tar.gz" -C "$tmpdir"

  local srcdir
  srcdir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d | head -1)
  [[ -z "$srcdir" ]] && srcdir="$tmpdir/${REPO_NAME}-${REPO_BRANCH}"

  # Install shared libraries into /usr/local/sbin/lib (sourced, not commands).
  mkdir -p /usr/local/sbin/lib
  if [[ -d "$srcdir/scripts/lib" ]]; then
    install -m 0644 "$srcdir/scripts/lib/"*.sh /usr/local/sbin/lib/
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

  # Install RDNS presets into /usr/local/sbin/rdns/presets and /etc/rdns/presets
  if [[ -d "$srcdir/scripts/rdns/presets" ]]; then
    mkdir -p /usr/local/sbin/rdns/presets /etc/rdns/presets
    cp -rf "$srcdir/scripts/rdns/presets/"*.json /usr/local/sbin/rdns/presets/ 2>/dev/null || true
    cp -rf "$srcdir/scripts/rdns/presets/"*.json /etc/rdns/presets/ 2>/dev/null || true
  fi

  # Cache prebuilt hardened binaries (Dropbear 2019.78, dnstt-server) locally if bundled
  if [[ -d "$srcdir/bin" ]]; then
    mkdir -p /usr/local/share/autoscript/bin
    cp -rf "$srcdir/bin/"* /usr/local/share/autoscript/bin/ 2>/dev/null || true
  fi
  if [[ -f "$srcdir/scripts/build/build-dropbear-2019.sh" ]]; then
    mkdir -p /usr/local/share/autoscript/build
    install -m 0755 "$srcdir/scripts/build/build-dropbear-2019.sh" /usr/local/share/autoscript/build/build-dropbear-2019.sh
  fi

  # Install the API, Uninstaller & Updater helper commands
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
  [[ -f "$srcdir/VERSION" ]] && cp -f "$srcdir/VERSION" /usr/local/sbin/VERSION 2>/dev/null || true

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

# --- Allowlist: all VPN / WebSocket / SSL / API / UDPGW / OpenVPN ports ---
for p in 22 3303 109 143 80 8080 8880 2052 2082 2086 2095 443 8443 2053 2083 2087 2096 8888 1194 3128 8000 8585; do
  firewall-cmd --permanent --zone=public --add-port="${p}/tcp" >/dev/null 2>&1
done
for p in 53 5300 443 8443 1194 2200 7100 7200 7300; do
  firewall-cmd --permanent --zone=public --add-port="${p}/udp" >/dev/null 2>&1
done
firewall-cmd --permanent --zone=trusted --add-interface=lo >/dev/null 2>&1 || true
firewall-cmd --permanent --zone=public --add-masquerade >/dev/null 2>&1 || true

firewall-cmd --reload >/dev/null 2>&1
[[ -x /usr/local/sbin/fix-firewall ]] && /usr/local/sbin/fix-firewall --quiet >/dev/null 2>&1 || true
print_success "Firewall & SELinux policies configured (strict allowlist)."
print_info "Internal services (Xray API 10085, WebAPI 9000, nginx 81/82) remain bound to 127.0.0.1."

# Enterprise Sysctl Tuning (RAM/CPU aware)
print_info "Applying network tuning for ${TIER} tier (${RAM_MB} MB RAM, ${CPU_CORES} CPU)..."
cat >/etc/sysctl.conf <<EOF
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
print_success "Network stack optimized (buffers: $((NET_BUF / 1048576)) MB, file-max: ${FILE_MAX})."

# Set Data Domain Server
print_header
echo -e "${LIGHT}Step 2: Server Identification${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
while true; do
  read -p "Input Domain Name: " domain
  domain=$(echo "$domain" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  if [[ -z "$domain" ]]; then
    print_error "Domain cannot be empty."
  elif [[ ! "$domain" =~ ^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    print_error "Invalid domain format (example: vpn.example.com)."
  else
    break
  fi
done
echo -e "$domain" >/etc/xray/domain
print_success "Domain set to: $domain"
sleep 1

# Install Prebuilt Hardened Static Dropbear 2019.78 (Zero Compile Time on EL9 & EL10)
dropbear_install_logic() {
  local db_ver="2019.78"
  local arch_label=""
  case "$(uname -m)" in
    x86_64|amd64)  arch_label="linux-amd64" ;;
    aarch64|arm64) arch_label="linux-arm64" ;;
  esac

  local archive_name="dropbear-${db_ver}-${arch_label}.tar.gz"
  local sha_name="dropbear-${db_ver}-${arch_label}.sha256"
  local prebuilt_ok=0
  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || pwd)"

  if [[ -n "$arch_label" ]]; then
    print_info "Installing Prebuilt Hardened Dropbear ${db_ver} (${arch_label})..."
    local db_tmp; db_tmp="$(mktemp -d /tmp/dropbear-prebuilt.XXXXXX)"
    chmod 700 "$db_tmp"

    local -a candidate_pairs=(
      "${script_dir}/bin/${archive_name}|${script_dir}/bin/${sha_name}"
      "/usr/local/share/autoscript/bin/${archive_name}|/usr/local/share/autoscript/bin/${sha_name}"
      "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${archive_name}|https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${sha_name}"
      "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/bin/${archive_name}|https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/bin/${sha_name}"
    )

    local pair src_arc src_sha exp_hash act_hash
    for pair in "${candidate_pairs[@]}"; do
      src_arc="${pair%%|*}"
      src_sha="${pair#*|}"
      rm -f "${db_tmp}/${archive_name}" "${db_tmp}/${sha_name}"

      if [[ "$src_arc" == http* ]]; then
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
          -o "${db_tmp}/${archive_name}" "$src_arc" 2>/dev/null || continue
        curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
          -o "${db_tmp}/${sha_name}" "$src_sha" 2>/dev/null || continue
      else
        [[ -s "$src_arc" && -s "$src_sha" ]] || continue
        cp -f "$src_arc" "${db_tmp}/${archive_name}"
        cp -f "$src_sha" "${db_tmp}/${sha_name}"
      fi

      exp_hash=$(awk '{print $1; exit}' "${db_tmp}/${sha_name}" | tr -d '[:space:]')
      act_hash=$(sha256sum "${db_tmp}/${archive_name}" | awk '{print $1}')
      if [[ -z "$exp_hash" || "$exp_hash" != "$act_hash" ]]; then
        print_warn "SHA-256 mismatch on ${src_arc}; trying next verified source..."
        continue
      fi

      mkdir -p "${db_tmp}/extract"
      if tar -xzf "${db_tmp}/${archive_name}" -C "${db_tmp}/extract" 2>/dev/null; then
        if (cd "${db_tmp}/extract" && [[ -s SHA256SUMS ]] && sha256sum -c SHA256SUMS >/dev/null 2>&1) && \
           [[ -f "${db_tmp}/extract/dropbear" && -f "${db_tmp}/extract/dropbearkey" ]]; then
          install -m 0755 "${db_tmp}/extract/dropbear" /usr/sbin/dropbear
          install -m 0755 "${db_tmp}/extract/dropbearkey" /usr/bin/dropbearkey
          ln -sf /usr/bin/dropbearkey /usr/sbin/dropbearkey
          if /usr/sbin/dropbear -V 2>&1 | grep -q "2019.78"; then
            prebuilt_ok=1
            print_success "Prebuilt Hardened Dropbear ${db_ver} SHA-256 verified & installed instantly."
            break
          fi
        fi
      fi
    done
    rm -rf "$db_tmp"
  fi

  # Emergency fallback: compile Dropbear 2019.78 from SHA-256-pinned upstream source if prebuilt unavailable
  if [[ "$prebuilt_ok" -ne 1 ]]; then
    print_warn "Prebuilt Dropbear ${db_ver} unavailable for $(uname -m); building hardened ${db_ver} from pinned source..."
    dnf groupinstall "Development Tools" -y >/dev/null 2>&1 || dnf install -y gcc make >/dev/null 2>&1
    dnf install -y zlib-devel libxcrypt-devel curl bzip2 >/dev/null 2>&1
    local db_src_sha="525965971272270995364a0eb01f35180d793182e63dd0b0c3eb0292291644a4"
    local db_tmp
    db_tmp=$(mktemp -d /tmp/dropbear-src.XXXXXX)
    chmod 700 "$db_tmp"
    cd "$db_tmp"
    curl -fsSL --proto '=https' --tlsv1.2 -o "dropbear-${db_ver}.tar.bz2" "https://matt.ucc.asn.au/dropbear/releases/dropbear-${db_ver}.tar.bz2" || \
      curl -fsSL --proto '=https' --tlsv1.2 -o "dropbear-${db_ver}.tar.bz2" "https://dropbear.nl/mirror/releases/dropbear-${db_ver}.tar.bz2"
    if ! echo "${db_src_sha}  dropbear-${db_ver}.tar.bz2" | sha256sum -c - >/dev/null 2>&1; then
      print_error "Dropbear ${db_ver} source SHA-256 verification failed."
      cd /root && rm -rf "$db_tmp"
      return 1
    fi
    tar xjf "dropbear-${db_ver}.tar.bz2" >/dev/null 2>&1
    cd "dropbear-${db_ver}"
    cat > localoptions.h <<'LOEOF'
#define DROPBEAR_SMALL_CODE 0
#define DROPBEAR_X11FWD 0
#define DROPBEAR_SVR_REMOTETCPFWD 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_DSS 0
#define DROPBEAR_3DES 0
#define DO_HOST_LOOKUP 0
#define DO_MOTD 0
#define MAX_UNAUTH_PER_IP 15
#define MAX_UNAUTH_CLIENTS 128
#define AUTH_TIMEOUT 60
LOEOF
    CFLAGS="-Os -fcommon -fstack-protector-strong" ./configure --prefix=/usr --sysconfdir=/etc/dropbear --disable-pam --disable-wtmp --disable-lastlog >/dev/null 2>&1
    make -j"$(nproc)" PROGRAMS="dropbear dropbearkey" >/dev/null 2>&1
    install -m 0755 dropbear /usr/sbin/dropbear
    install -m 0755 dropbearkey /usr/bin/dropbearkey
    ln -sf /usr/bin/dropbearkey /usr/sbin/dropbearkey
    cd /root
    rm -rf "$db_tmp"
  fi

  cat >/etc/systemd/system/dropbear.service <<'EOF'
[Unit]
Description=Dropbear 2019.78 Hardened SSH Server
After=network.target rsyslog.service
StartLimitIntervalSec=0

[Service]
Type=simple
KillMode=process
# No -E: log via syslog (authpriv) so logins reach /var/log/secure.
# -F foreground | -w block root | -g block root password | -K 60 keepalive | -I 300 idle | -T 5 max tries
ExecStart=/usr/sbin/dropbear -F -w -g -K 60 -I 300 -T 5 -p 109 -p 143 -b /etc/issue.net -r /etc/dropbear/dropbear_rsa_host_key -r /etc/dropbear/dropbear_ecdsa_host_key -W 65536
Restart=always
RestartSec=1s
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF

  mkdir -p /etc/dropbear
  chmod 700 /etc/dropbear
  [[ -f /etc/dropbear/dropbear_rsa_host_key ]] || /usr/bin/dropbearkey -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
  [[ -f /etc/dropbear/dropbear_ecdsa_host_key ]] || /usr/bin/dropbearkey -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null 2>&1
  chmod 600 /etc/dropbear/dropbear_*_host_key 2>/dev/null || true
  echo -e "Enterprise VPN Server" >/etc/issue.net
  systemctl daemon-reload
  systemctl enable dropbear --now >/dev/null 2>&1
  systemctl restart dropbear >/dev/null 2>&1
  check_service dropbear
  print_success "Hardened Dropbear 2019.78 running on ports 109 and 143."
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
SSHWS_VERSION="v1.3.1"
sshws_install_logic() {
  print_info "Installing SSH-WebSocket proxy (GO-TUNNEL PRO ${SSHWS_VERSION})..."

  # Detect architecture -> release asset suffix.
  local arch asset
  case "$(uname -m)" in
  x86_64) arch="linux-amd64" ;;
  aarch64) arch="linux-arm64" ;;
  armv7l) arch="linux-armv7" ;;
  *)
    print_error "Unsupported architecture: $(uname -m)"
    return 1
    ;;
  esac
  asset="ssh-ws-${SSHWS_VERSION}-${arch}.tar.gz"

  local base="https://github.com/risqinf/websocket-proxy/releases/download/${SSHWS_VERSION}"
  local tmp
  tmp="$(mktemp -d)"

  if ! wget -qO "${tmp}/ssh-ws.tar.gz" "${base}/${asset}"; then
    print_error "Failed to download ${asset}."
    rm -rf "$tmp"
    return 1
  fi

  # Verify checksum against the release checksums.txt (best effort).
  if wget -qO "${tmp}/checksums.txt" "${base}/checksums.txt"; then
    local want got
    want=$(grep -E "  ?${asset}\$" "${tmp}/checksums.txt" | awk '{print $1}')
    got=$(sha256sum "${tmp}/ssh-ws.tar.gz" | awk '{print $1}')
    if [[ -n "$want" && "$want" != "$got" ]]; then
      print_error "Checksum mismatch for ${asset}. Aborting ssh-ws install."
      rm -rf "$tmp"
      return 1
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
    rm -rf "$tmp"
    return 1
  fi
  install -m 0755 "$bin" /usr/local/bin/ssh-ws
  rm -rf "$tmp"

  # Generate a random per-connection password (optional; clients send X-Pass).
  # Leave auth disabled by default so existing client configs keep working;
  # the proxy is only reachable via nginx/HAProxy on the public TLS port.
  cat >/etc/systemd/system/ssh-ws.service <<'EOF'
[Unit]
Description=GO-TUNNEL PRO SSH WebSocket Proxy
After=network.target dropbear.service
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/ssh-ws -b 0.0.0.0 -p 8888 -t 127.0.0.1:109 \
  -l /var/log/ssh-ws.log --auth-log /var/log/secure --api-port 8081
Restart=always
RestartSec=1s
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity

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
  cat >/etc/xray/config.json <<EOF
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
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
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
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
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
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/"
        }
      }
    },
    {
      "tag": "vless-hu",
      "listen": "127.0.0.1",
      "port": 10011,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "/vless-hu"
        }
      }
    },
    {
      "tag": "trojan-hu",
      "listen": "127.0.0.1",
      "port": 10012,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${uuid}"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "/trojan-hu"
        }
      }
    },
    {
      "tag": "vmess-hu",
      "listen": "127.0.0.1",
      "port": 10013,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "httpupgrade",
        "httpupgradeSettings": {
          "path": "/vmess-hu"
        }
      }
    },
    {
      "tag": "vless-xhttp",
      "listen": "127.0.0.1",
      "port": 10021,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/vless-xhttp",
          "mode": "auto"
        }
      }
    },
    {
      "tag": "trojan-xhttp",
      "listen": "127.0.0.1",
      "port": 10022,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${uuid}"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/trojan-xhttp",
          "mode": "auto"
        }
      }
    },
    {
      "tag": "vmess-xhttp",
      "listen": "127.0.0.1",
      "port": 10023,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/vmess-xhttp",
          "mode": "auto"
        }
      }
    },
    {
      "tag": "vless-grpc",
      "listen": "127.0.0.1",
      "port": 10031,
      "protocol": "vless",
      "settings": {
        "decryption": "none",
        "clients": [
          {
            "id": "${uuid}"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vless-grpc"
        }
      }
    },
    {
      "tag": "trojan-grpc",
      "listen": "127.0.0.1",
      "port": 10032,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "${uuid}"
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "trojan-grpc"
        }
      }
    },
    {
      "tag": "vmess-grpc",
      "listen": "127.0.0.1",
      "port": 10033,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "alterId": 0
          }
        ]
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": false
      },
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {
          "serviceName": "vmess-grpc"
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
          "127.0.0.0/8",
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

  # Direct TLS-verified download + SHA-256 verification of Xray-core (zero curl|bash)
  local xray_ver="v25.10.15"
  local xray_arch="64"
  case "$(uname -m)" in
    x86_64|amd64)   xray_arch="64" ;;
    aarch64|arm64)  xray_arch="arm64-v8a" ;;
    armv7l|armv7*)  xray_arch="arm32-v7a" ;;
  esac
  local xray_zip="Xray-linux-${xray_arch}.zip"
  local xray_base="https://github.com/XTLS/Xray-core/releases/download/${xray_ver}"
  local xray_tmp
  xray_tmp=$(mktemp -d /tmp/xray-install.XXXXXX)
  chmod 700 "$xray_tmp"
  dnf install -y unzip >/dev/null 2>&1 || true
  if curl -fsSL --proto '=https' --tlsv1.2 -o "${xray_tmp}/${xray_zip}" "${xray_base}/${xray_zip}" && \
     curl -fsSL --proto '=https' --tlsv1.2 -o "${xray_tmp}/${xray_zip}.dgst" "${xray_base}/${xray_zip}.dgst"; then
    local exp_sha256 act_sha256
    exp_sha256=$(awk -F'= ' '/^SHA2-256=/ {print $2; exit}' "${xray_tmp}/${xray_zip}.dgst" | tr -d '[:space:]')
    act_sha256=$(sha256sum "${xray_tmp}/${xray_zip}" | awk '{print $1}')
    if [[ -n "$exp_sha256" && "$exp_sha256" != "$act_sha256" ]]; then
      print_error "Xray SHA-256 verification failed! Expected ${exp_sha256}, got ${act_sha256}."
      rm -rf "$xray_tmp"
      exit 1
    fi
    mkdir -p /usr/local/bin /usr/local/share/xray
    unzip -oq "${xray_tmp}/${xray_zip}" -d "$xray_tmp/extracted"
    install -m 0755 "$xray_tmp/extracted/xray" /usr/local/bin/xray
    [[ -f "$xray_tmp/extracted/geoip.dat" ]] && install -m 0644 "$xray_tmp/extracted/geoip.dat" /usr/local/share/xray/geoip.dat
    [[ -f "$xray_tmp/extracted/geosite.dat" ]] && install -m 0644 "$xray_tmp/extracted/geosite.dat" /usr/local/share/xray/geosite.dat
    print_success "Xray-core ${xray_ver} SHA-256 verified and installed."
  else
    print_error "Failed to download Xray-core ${xray_ver} from official GitHub release."
    rm -rf "$xray_tmp"
    exit 1
  fi
  rm -rf "$xray_tmp"

  mkdir -p /var/log/xray
  touch /var/log/xray/{access,error}.log
  chown -R root:root /var/log/xray
  chmod 644 /var/log/xray/*.log

  # Remove any service unit the XTLS installer may have created, then write
  # our own (xray run -config, with reload + resource limits).
  rm -f /etc/systemd/system/xray.service /etc/systemd/system/xray@.service 2>/dev/null
  rm -rf /etc/systemd/system/xray.service.d 2>/dev/null

  cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target nss-lookup.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=1s

# Resource Limits (No artificial ulimit or core-dump bottlenecks)
LimitNOFILE=1048576
LimitNPROC=65535
LimitFSIZE=infinity
LimitAS=infinity
LimitCORE=0
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
print_info "Configuring SELinux booleans and port labels for the proxy stack..."
if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
  dnf install -y policycoreutils policycoreutils-python-utils >/dev/null 2>&1 || true
  setsebool -P httpd_can_network_connect 1 2>/dev/null || true
  setsebool -P httpd_can_network_connect_db 1 2>/dev/null || true
  setsebool -P httpd_can_network_relay 1 2>/dev/null || true
  setsebool -P httpd_setrlimit 1 2>/dev/null || true
  setsebool -P haproxy_connect_any 1 2>/dev/null || true
  setsebool -P nis_enabled 1 2>/dev/null || true
  if command -v semanage >/dev/null 2>&1; then
    for sp in 81 82 8080 8443 8888 8585 9000; do
      semanage port -a -t http_port_t -p tcp "$sp" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$sp" 2>/dev/null || true
    done
  fi
  print_success "SELinux booleans and http_port_t labels applied."
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

  cat >/etc/nginx/nginx.conf <<EOF
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

  cat >/etc/nginx/risqinf.conf <<EOF
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

upstream vless_hu {
    server 127.0.0.1:10011;
    keepalive 32;
}

upstream trojan_hu {
    server 127.0.0.1:10012;
    keepalive 32;
}

upstream vmess_hu {
    server 127.0.0.1:10013;
    keepalive 32;
}

upstream vless_xhttp {
    server 127.0.0.1:10021;
    keepalive 32;
}

upstream trojan_xhttp {
    server 127.0.0.1:10022;
    keepalive 32;
}

upstream vmess_xhttp {
    server 127.0.0.1:10023;
    keepalive 32;
}

upstream noobz_ws {
    server 127.0.0.1:8585;
    keepalive 32;
}

upstream api_backend {
    server 127.0.0.1:9000;
    keepalive 256;
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

    # Explicit protocol paths.
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

    # HTTPUpgrade paths
    location /vless-hu {
        proxy_pass http://vless_hu;
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

    location /vmess-hu {
        proxy_pass http://vmess_hu;
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

    location /trojan-hu {
        proxy_pass http://trojan_hu;
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

    # XHTTP (SplitHTTP) paths
    location ^~ /vless-xhttp {
        proxy_pass http://vless_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }

    location ^~ /vmess-xhttp {
        proxy_pass http://vmess_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }

    location ^~ /trojan-xhttp {
        proxy_pass http://trojan_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
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

    # Explicit NoobzVPN path.
    location ~* ^/(noobz|noobz-ws) {
        if (\$http_upgrade != "websocket") { return 444; }
        proxy_pass http://noobz_ws;
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

    # REST API Daemon (api-server) with persistent keepalive pool.
    location /api/ {
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_next_upstream off;
        client_max_body_size 8m;
    }

    # VMESS multipath (any other path) OR SSH-WS, decided by the handshake.
    location / {
        if (\$http_upgrade !~* "websocket") { return 444; }
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

# Dedicated HTTP/2 server block for gRPC, XHTTP, and HTTPUpgrade
server {
    listen 127.0.0.1:82 default_server proxy_protocol;
    http2 on;
    server_name ${domain};

    # gRPC inbounds
    location ^~ /vless-grpc {
        grpc_pass grpc://127.0.0.1:10031;
        grpc_read_timeout 7d;
        grpc_send_timeout 7d;
        grpc_set_header X-Real-IP \$remote_addr;
    }

    location ^~ /trojan-grpc {
        grpc_pass grpc://127.0.0.1:10032;
        grpc_read_timeout 7d;
        grpc_send_timeout 7d;
        grpc_set_header X-Real-IP \$remote_addr;
    }

    location ^~ /vmess-grpc {
        grpc_pass grpc://127.0.0.1:10033;
        grpc_read_timeout 7d;
        grpc_send_timeout 7d;
        grpc_set_header X-Real-IP \$remote_addr;
    }

    # XHTTP (SplitHTTP) inbounds over HTTP/2
    location ^~ /vless-xhttp {
        proxy_pass http://vless_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }

    location ^~ /vmess-xhttp {
        proxy_pass http://vmess_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }

    location ^~ /trojan-xhttp {
        proxy_pass http://trojan_xhttp;
        proxy_http_version 1.1;
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 7d;
        proxy_send_timeout 7d;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 0;
    }

    # HTTPUpgrade inbounds over HTTP/2
    location ^~ /vless-hu {
        proxy_pass http://vless_hu;
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

    location ^~ /vmess-hu {
        proxy_pass http://vmess_hu;
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

    location ^~ /trojan-hu {
        proxy_pass http://trojan_hu;
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

    # Explicit NoobzVPN path over port 82.
    location ~* ^/(noobz|noobz-ws) {
        if (\$http_upgrade != "websocket") { return 444; }
        proxy_pass http://noobz_ws;
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

    # OpenVPN client config downloads over HTTP/2 (:443 ALPN h2).
    location /risqinf/ {
        alias /var/www/html/risqinf/;
        autoindex on;
    }

    # REST API Daemon over HTTP/2 (:443 ALPN h2).
    location /api/ {
        proxy_pass http://api_backend;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_connect_timeout 10s;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
        proxy_next_upstream off;
        client_max_body_size 8m;
    }
}
EOF
  [[ -x /usr/local/sbin/fix-firewall ]] && /usr/local/sbin/fix-firewall --quiet >/dev/null 2>&1 || true
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

  mkdir -p /etc/haproxy /run/haproxy
  cat /etc/xray/xray.crt /etc/xray/xray.key | tee /etc/haproxy/haproxy.pem >/dev/null
  chmod 600 /etc/haproxy/haproxy.pem

  cat >/etc/haproxy/haproxy.cfg <<EOF
global
    log /dev/log local0
    maxconn ${HA_MAXCONN}
    user haproxy
    group haproxy
    daemon
    stats socket /run/haproxy/admin.sock mode 600 level admin
    tune.ssl.default-dh-param 2048

defaults
    log global
    mode tcp
    option tcplog
    timeout connect 5s
    timeout client 30m
    timeout server 30m

# Plain HTTP on :80 and :8080 -> nginx (WS/HU/XHTTP over HTTP, ACME, downloads, API).
frontend http_in
    bind *:80
    bind *:8080
    mode tcp
    default_backend nginx_http

# TLS on :443 and :8443 with ALPN (h2,http/1.1).
# HAProxy terminates TLS, then splits traffic:
#   * ALPN h2 (gRPC/API)          -> nginx HTTP/2 backend (:82)
#   * starts with HTTP method     -> nginx HTTP/1.1 backend (:81)
#   * anything else (raw SSH)     -> Dropbear directly (:109) (Direct SSH SSL/TLS)
frontend tls_in
    bind *:443 ssl crt /etc/haproxy/haproxy.pem alpn h2,http/1.1
    bind *:8443 ssl crt /etc/haproxy/haproxy.pem alpn h2,http/1.1
    mode tcp
    tcp-request inspect-delay 5s
    acl is_h2 ssl_fc_alpn -i h2
    acl is_http req.payload(0,10) -m reg -i ^(GET|POST|HEAD|PUT|OPTIONS|DELETE|PATCH|TRACE|CONNECT)
    tcp-request content accept if { req.len gt 0 }
    use_backend nginx_h2 if is_h2
    use_backend nginx_http if is_http
    default_backend ssh_direct

backend nginx_h2
    mode tcp
    server nginx_h2_node 127.0.0.1:82 send-proxy check

backend nginx_http
    mode tcp
    server nginx_node 127.0.0.1:81 send-proxy check

backend ssh_direct
    mode tcp
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
cat >/etc/systemd/system/autoexpire.service <<'EOF'
[Unit]
Description=Auto-expire accounts (all protocols)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/expire-all
EOF

cat >/etc/systemd/system/autoexpire.timer <<'EOF'
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
cat >/etc/systemd/system/limit-ip-ssh.service <<'EOF'
[Unit]
Description=SSH IP-limit enforcement
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/limit-ip-ssh
EOF

cat >/etc/systemd/system/limit-ip-ssh.timer <<'EOF'
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
cat >/etc/systemd/system/backup.service <<'EOF'
[Unit]
Description=Account/database backup

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup
EOF

cat >/etc/systemd/system/backup.timer <<'EOF'
[Unit]
Description=Run backup hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Daily log maintenance.
cat >/etc/systemd/system/fixlog.service <<'EOF'
[Unit]
Description=Log maintenance (cap sizes, keep recent monitor data)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/fixlog
EOF

cat >/etc/systemd/system/fixlog.timer <<'EOF'
[Unit]
Description=Run log maintenance daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload >/dev/null 2>&1
systemctl enable --now autoexpire.timer limit-ip-ssh.timer backup.timer fixlog.timer >/dev/null 2>&1

# Install Speedtest CLI securely (direct HTTPS archive, zero curl|bash repo script)
install_speedtest_secure() {
  local st_arch="x86_64"
  case "$(uname -m)" in
    x86_64|amd64)        st_arch="x86_64" ;;
    aarch64|arm64)       st_arch="aarch64" ;;
    armv7l|armv7*)       st_arch="armhf" ;;
  esac
  local st_tmp
  st_tmp=$(mktemp -d /tmp/speedtest.XXXXXX)
  if curl -fsSL --proto '=https' --tlsv1.2 -m 30 -o "${st_tmp}/st.tgz" \
       "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${st_arch}.tgz" 2>/dev/null; then
    tar -xzf "${st_tmp}/st.tgz" -C "$st_tmp" 2>/dev/null && \
      [[ -f "${st_tmp}/speedtest" ]] && install -m 0755 "${st_tmp}/speedtest" /usr/local/bin/speedtest
  fi
  rm -rf "$st_tmp"
}
install_speedtest_secure

# Setup Limit IP & Quota Services (SSH All-Protocol + Xray)
cat >/etc/systemd/system/quota-ssh.service <<EOF
[Unit]
Description=SSH All-Protocol Usage Quota Enforcement
After=network.target dropbear.service sshd.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/loop-quota-ssh
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/quota.service <<EOF
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

cat >/etc/systemd/system/limit-ip-vless.service <<EOF
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

cat >/etc/systemd/system/quota-trojan.service <<EOF
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

cat >/etc/systemd/system/limit-ip-trojan.service <<EOF
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

cat >/etc/systemd/system/quota-vmess.service <<EOF
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

cat >/etc/systemd/system/limit-ip-vmess.service <<EOF
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

systemctl daemon-reload >/dev/null 2>&1
systemctl enable quota-ssh quota limit-ip-vless --now >/dev/null 2>&1
systemctl enable quota-trojan limit-ip-trojan --now >/dev/null 2>&1
systemctl enable quota-vmess limit-ip-vmess --now >/dev/null 2>&1
for svc in quota-ssh quota limit-ip-vless quota-trojan limit-ip-trojan quota-vmess limit-ip-vmess; do
  check_service "$svc" || print_warn "Looping service '$svc' not active (will retry via Restart=on-failure)."
done

# Api Server
api_server_install_logic() {
  print_info "Building and installing API server..."

  local script_dir; script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$script_dir/install-api.sh" ]]; then
    bash "$script_dir/install-api.sh"
    return $?
  fi

  # Fallback manual install
  if ! command -v go &>/dev/null; then
    print_info "Installing Go..."
    dnf install -y golang >/dev/null 2>&1
  fi

  API_DIR="${script_dir}/files"
  if [[ ! -d "$API_DIR" ]]; then
    print_error "API source directory not found: $API_DIR"
    return 1
  fi

  cd "$API_DIR"
  go mod tidy

  CGO_ENABLED=0 go build \
    -ldflags="-s -w" \
    -o /usr/local/bin/api-server \
    ./cmd/server/main.go

  chmod +x /usr/local/bin/api-server
  ln -sf /usr/local/bin/api-server /usr/local/bin/autoscript-api

  mkdir -p /etc/api
  chmod 700 /etc/api

  cp "$API_DIR/api-server.service" /etc/systemd/system/api-server.service
  chmod 644 /etc/systemd/system/api-server.service
  systemctl daemon-reload >/dev/null 2>&1
  systemctl enable api-server --now >/dev/null 2>&1

  local token; token=$(sqlite3 /etc/api/api.db "SELECT token FROM tokens LIMIT 1;" 2>/dev/null || true)
  [[ -z "$token" && -f /etc/api/key ]] && token=$(cat /etc/api/key)
  if [[ -n "$token" ]]; then
    echo ""
    echo -e "${GREEN}=== API SERVER TOKEN ===${NC}"
    echo -e "${BLUE}Token:${NC} $token"
    echo ""
  fi
}

if [[ -f "/usr/local/bin/api-server" ]]; then
  print_warn "API server is already installed."
  echo -e "1) Skip\n2) Rebuild"
  read -p "Select [1-2]: " api_choice
  [[ "$api_choice" == "2" ]] && api_server_install_logic
else
  api_server_install_logic
fi

clear
echo -e "clear ; menu" >/root/.profile

# Dynamic Swap Management (KVM Optimized)
swap_install_logic() {
  echo -e "———————————————————————————————————————————————————————"
  echo -e "            CONFIGURING DYNAMIC SWAP (RAM-aware)"
  echo -e "———————————————————————————————————————————————————————"

  # Swap sizing is driven by RAM (most needed on low-RAM VPS), then capped
  # by available disk. Applies to all virt types (not just KVM).
  FREE_DISK=$(df -k / | awk 'NR==2 {print $4}') # KB free on /
  # Target swap by RAM tier.
  if ((RAM_MB <= 1280)); then
    SWAP_SIZE_GB=2 # ~1GB RAM -> 2GB swap
  elif ((RAM_MB <= 2560)); then
    SWAP_SIZE_GB=2 # ~2GB RAM -> 2GB swap
  elif ((RAM_MB <= 5120)); then
    SWAP_SIZE_GB=4 # ~4GB RAM -> 4GB swap
  else
    SWAP_SIZE_GB=4 # >4GB RAM -> 4GB swap (plenty)
  fi
  # Cap by disk: need swap size + 5GB headroom free.
  NEED_KB=$(((SWAP_SIZE_GB * 1024 * 1024) + (5 * 1024 * 1024)))
  while ((SWAP_SIZE_GB > 0)) && ((FREE_DISK < NEED_KB)); do
    SWAP_SIZE_GB=$((SWAP_SIZE_GB - 1))
    NEED_KB=$(((SWAP_SIZE_GB * 1024 * 1024) + (5 * 1024 * 1024)))
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
      echo "/swapfile none swap defaults 0 0" >>/etc/fstab

      # Swappiness: lean on swap more on low-RAM boxes, less on big ones.
      if ((RAM_MB <= 1280)); then SWAPPINESS=60; else SWAPPINESS=15; fi
      sysctl -w vm.swappiness=${SWAPPINESS} >/dev/null 2>&1
      echo "vm.swappiness=${SWAPPINESS}" >>/etc/sysctl.conf

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

# Setup OpenVPN
WEB_DIR="/var/www/html/risqinf/openvpn"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
ovpn_install_logic() {
  echo "=================================================="
  echo "INSTALLING OPENVPN..."
  echo "=================================================="
  WEB_DIR="/var/www/html/risqinf/openvpn"
  EASYRSA_DIR="/etc/openvpn/easy-rsa"
  dnf install -y openvpn easy-rsa >/dev/null 2>&1
  dnf install -y iptables-nft >/dev/null 2>&1 || dnf install -y iptables-services >/dev/null 2>&1 || true
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
  if [[ ! -f "$PLUGIN_PAM" ]]; then
    local found_pam
    found_pam=$(find /usr/lib64 /usr/lib -name "openvpn-plugin-auth-pam.so" 2>/dev/null | head -1 || true)
    [[ -n "$found_pam" ]] && PLUGIN_PAM="$found_pam"
  fi

  # TCP Server Config
  cat >/etc/openvpn/server/server-tcp-1194.conf <<EOF
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
status /etc/openvpn/server/openvpn-status-tcp.log 5
status-version 2
verb 3
EOF

  CA_DATA=$(cat /etc/openvpn/server/ca.crt)
  TA_DATA=$(cat /etc/openvpn/server/ta.key)
  MYIP=$(curl -s http://checkip.amazonaws.com 2>/dev/null)
  [[ -z "$MYIP" ]] && MYIP=$(hostname -I | awk '{print $1}')

  # Client OVPN Generation (TCP only - using IP VPS for CDN/proxied domain compatibility)
  cat >$WEB_DIR/tcp.ovpn <<EOF
client
dev tun
proto tcp
remote $MYIP 1194
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
  echo 1 >/proc/sys/net/ipv4/ip_forward
  sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
  sysctl -p >/dev/null 2>&1
  firewall-cmd --zone=public --add-port=1194/tcp --permanent >/dev/null 2>&1 || true
  firewall-cmd --add-masquerade --permanent >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true

  systemctl enable openvpn-server@server-tcp-1194 >/dev/null 2>&1
  systemctl restart openvpn-server@server-tcp-1194 >/dev/null 2>&1
  check_service "openvpn-server@server-tcp-1194" || print_warn "OpenVPN TCP not active."
}

if [[ -f "/etc/openvpn/server/server-tcp-1194.conf" && -f "$WEB_DIR/tcp.ovpn" ]]; then
  echo -e "\e[32m[SKIP]\e[0m OpenVPN is already installed."
else
  ovpn_install_logic
fi

# ---- Install & Configure Squid Proxy (Port 3128 - Hardened Destination ACL) ----
squid_install_logic() {
  echo -e "\e[32m[INFO]\e[0m Installing & Hardening Squid Proxy (Port 3128)..."
  dnf install squid -y >/dev/null 2>&1

  local vps_ip
  vps_ip=$(curl -fsSL --max-time 4 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]')
  [[ -z "$vps_ip" ]] && vps_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

  cat >/etc/squid/squid.conf <<EOF
acl SSL_ports port 443 8443 22 109 143 3303 1194 8585
acl Safe_ports port 80 8080 8880 8888 443 8443 22 109 143 3303 1194 8585
acl CONNECT method CONNECT
acl to_vps_ip dst ${vps_ip:-127.0.0.1}/32
acl to_vps_dom dstdomain ${domain}

http_access deny !Safe_ports
http_access deny CONNECT !SSL_ports
http_access deny manager
http_access deny to_localhost
http_access deny to_linklocal
http_access allow to_vps_ip
http_access allow to_vps_dom
http_access allow localhost
http_access deny all

http_port 3128
max_filedescriptors 65535
cache deny all
cache_mem 0 MB
logfile_rotate 0
access_log none
cache_store_log none
via off
forwarded_for delete
httpd_suppress_version_string on
coredump_dir /var/spool/squid
EOF

  systemctl enable squid >/dev/null 2>&1
  systemctl restart squid >/dev/null 2>&1
  firewall-cmd --zone=public --add-port=3128/tcp --permanent >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
}

squid_install_logic

# ---- Install & Configure NoobzVpn Server (Port 8585 -> Nginx /noobz) ----
noobz_install_logic() {
  print_info "Installing & Configuring NoobzVpn Server..."
  mkdir -p /etc/noobzvpns
  chmod 755 /etc/noobzvpns

  local arch; arch=$(uname -m)
  local bin_url="https://github.com/noobz-id/noobzvpns/raw/master/noobzvpns.x86-64"
  [[ "$arch" == "aarch64" || "$arch" == "arm64" ]] && bin_url="https://github.com/noobz-id/noobzvpns/raw/master/noobzvpns.aarch64"

  curl -sSL --connect-timeout 10 -o /usr/bin/noobzvpns "$bin_url" 2>/dev/null || wget -q -O /usr/bin/noobzvpns "$bin_url" 2>/dev/null
  chmod +x /usr/bin/noobzvpns

  if [[ ! -x /usr/bin/noobzvpns ]]; then
    print_warn "Failed to download noobzvpns binary. NoobzVPN service skipped."
    return 0
  fi

  # Ensure SSL certificate and key exist for NoobzVPN TLS parser
  if [[ -f /etc/xray/xray.key && -f /etc/xray/xray.crt ]]; then
    cp -f /etc/xray/xray.key /etc/noobzvpns/key.pem
    cp -f /etc/xray/xray.crt /etc/noobzvpns/cert.pem
  else
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/CN=noobzvpns" \
      -keyout /etc/noobzvpns/key.pem -out /etc/noobzvpns/cert.pem >/dev/null 2>&1 || true
  fi
  chmod 600 /etc/noobzvpns/key.pem /etc/noobzvpns/cert.pem 2>/dev/null || true

  # Ensure db_user.json exists
  if [[ ! -f /etc/noobzvpns/db_user.json ]]; then
    cat >/etc/noobzvpns/db_user.json <<'EOF'
{
  "version": 331,
  "users": {}
}
EOF
    chmod 600 /etc/noobzvpns/db_user.json
  else
    if grep -q '"version": 1' /etc/noobzvpns/db_user.json 2>/dev/null; then
      sed -i 's/"version": 1/"version": 331/' /etc/noobzvpns/db_user.json
    fi
  fi

  cat >/etc/noobzvpns/config.toml <<'EOF'
# NoobzVpn-Server Configuration File
# (c) Noobz-ID Software

[tcp_plain]
local_host = ["8585"]

[tcp_ssl]
#local_host = ["443"]
tls_version = "AUTO"
key_pem = "/etc/noobzvpns/key.pem"
cert_pem = "/etc/noobzvpns/cert.pem"

[client]
ip_version = "AUTO"
tcp_initial_timeout = 30
resolv_conf = "/etc/resolv.conf"
identifier = "risqinf"
banner = "You are connected to noobzvpn-server"
tcp_http_response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n"

[remote]
tcp_connect_timeout = 30
tcp_idle_timeout = 900
udp_connect_timeout = 30
udp_idle_timeout = 60
udp_dns_timeout = 10

[database]
database_monitor_timer = 30
device_timeout = 5

[runtime]
worker_threads = 0
EOF

  chmod 600 /etc/noobzvpns/config.toml

  cat >/etc/systemd/system/noobzvpns.service <<'EOF'
[Unit]
Description=NoobzVpn-Server
Wants=network-online.target
After=network.target network-online.target

[Service]
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
User=root
Type=simple
WorkingDirectory=/etc/noobzvpns
TimeoutStopSec=1
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity
ExecStart=/usr/bin/noobzvpns start-server
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable noobzvpns >/dev/null 2>&1
  systemctl restart noobzvpns >/dev/null 2>&1
  check_service "noobzvpns" || print_warn "NoobzVpn service not active."
}

noobz_install_logic

# Apply final Rocky Linux 9 extreme optimization + SELinux/Firewall verification
[[ -x /usr/local/sbin/optimize-rocky ]] && /usr/local/sbin/optimize-rocky --quiet >/dev/null 2>&1 || true
[[ -x /usr/local/sbin/fix-firewall ]] && /usr/local/sbin/fix-firewall --quiet >/dev/null 2>&1 || true

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
