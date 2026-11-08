#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Extreme Enterprise Linux 9 & 10 Kernel, ZRAM, Conntrack & Daemon
#              Memory Tuning (Rocky 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10)
# Version: 5.6.1
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
  err "optimize-rocky must be run as root."
  exit 1
fi

QUIET="${1:-}"
log_info() { [[ "$QUIET" == "--quiet" ]] || info "$1"; }
log_ok()   { [[ "$QUIET" == "--quiet" ]] || ok "$1"; }
log_warn() { [[ "$QUIET" == "--quiet" ]] || warn "$1"; }

# ---------------------------------------------------------------------------
# 1. Hardware Resource Profiling
# ---------------------------------------------------------------------------
CPU_CORES=$(nproc 2>/dev/null || echo 1)
[[ "$CPU_CORES" =~ ^[0-9]+$ ]] || CPU_CORES=1
RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 1024)
[[ "$RAM_MB" =~ ^[0-9]+$ ]] || RAM_MB=1024

if (( RAM_MB <= 1280 )); then
  TIER="1GB-EXTREME"
  TCP_BUF_MAX=2097152         # 2 MB max per socket -> prevents socket buffer OOM with 500+ users
  TCP_MEM="12288 16384 32768" # 48MB / 64MB / 128MB kernel TCP memory pressure bounds
  CONNTRACK_MAX=131072
  ORPHANS_MAX=4096
  XRAY_MEMLIMIT="220MiB"
  XRAY_GOGC="50"
  XRAY_BUF_SIZE="1"           # 1 MB Xray ray buffer -> halves per-tunnel memory!
  API_MEMLIMIT="96MiB"
  API_GOGC="50"
  SSHWS_MEMLIMIT="96MiB"
  ZRAM_PCT=50
  SWAP_GB=2
  SWAPPINESS=80
elif (( RAM_MB <= 2560 )); then
  TIER="2GB-OPTIMIZED"
  TCP_BUF_MAX=8388608
  TCP_MEM="24576 32768 65536"
  CONNTRACK_MAX=262144
  ORPHANS_MAX=8192
  XRAY_MEMLIMIT="512MiB"
  XRAY_GOGC="75"
  XRAY_BUF_SIZE="2"
  API_MEMLIMIT="192MiB"
  API_GOGC="75"
  SSHWS_MEMLIMIT="192MiB"
  ZRAM_PCT=50
  SWAP_GB=2
  SWAPPINESS=60
elif (( RAM_MB <= 5120 )); then
  TIER="4GB-HIGH"
  TCP_BUF_MAX=33554432
  TCP_MEM="65536 131072 262144"
  CONNTRACK_MAX=524288
  ORPHANS_MAX=32768
  XRAY_MEMLIMIT="1536MiB"
  XRAY_GOGC="100"
  XRAY_BUF_SIZE="4"
  API_MEMLIMIT="512MiB"
  API_GOGC="100"
  SSHWS_MEMLIMIT="384MiB"
  ZRAM_PCT=35
  SWAP_GB=4
  SWAPPINESS=30
else
  TIER="8GB+-ENTERPRISE"
  TCP_BUF_MAX=67108864
  TCP_MEM="131072 262144 524288"
  CONNTRACK_MAX=1048576
  ORPHANS_MAX=65536
  XRAY_MEMLIMIT="3072MiB"
  XRAY_GOGC="100"
  XRAY_BUF_SIZE="4"
  API_MEMLIMIT="1024MiB"
  API_GOGC="100"
  SSHWS_MEMLIMIT="512MiB"
  ZRAM_PCT=25
  SWAP_GB=4
  SWAPPINESS=15
fi

OS_PRETTY="Enterprise Linux"
if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_PRETTY="${PRETTY_NAME:-Enterprise Linux}"
fi

log_info "Applying ${OS_PRETTY} Extreme Optimization [${TIER}] (${CPU_CORES} vCPU / ${RAM_MB} MB RAM)..."

# ---------------------------------------------------------------------------
# 2. Reclaim Reserved crashkernel/kdump Memory & Trim EL9 Bloat Services
#    On Rocky Linux 9, kdump reserves 160-256MB of 1GB RAM!
# ---------------------------------------------------------------------------
trim_el9_bloat() {
  local bloat_units=(
    kdump.service
    cockpit.socket
    cockpit.service
    ModemManager.service
    bluetooth.service
    cups.service
    avahi-daemon.service
    avahi-daemon.socket
  )
  local u
  for u in "${bloat_units[@]}"; do
    if systemctl list-unit-files "$u" >/dev/null 2>&1; then
      systemctl disable --now "$u" >/dev/null 2>&1 || true
    fi
  done

  # Reclaim crashkernel RAM on next boot if grubby is installed
  if (( RAM_MB <= 2560 )) && command -v grubby >/dev/null 2>&1; then
    grubby --update-kernel=ALL --args="crashkernel=no" >/dev/null 2>&1 || true
  fi

  # Cap systemd-journald memory & disk footprint so tmpfs /run/log never bloats
  mkdir -p /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/00-autoscript.conf <<'EOF'
[Journal]
SystemMaxUse=32M
SystemKeepFree=64M
RuntimeMaxUse=16M
Compress=yes
RateLimitIntervalSec=30s
RateLimitBurst=2000
ForwardToWall=no
EOF
  systemctl restart systemd-journald >/dev/null 2>&1 || true
  log_ok "Trimmed non-essential EL9 background services and capped journald to 16MB RAM / 32MB disk."
}

# ---------------------------------------------------------------------------
# 3. Enable Kernel ZRAM Compressed RAM Swap + Fallback Disk Swap
# ---------------------------------------------------------------------------
setup_zram_and_swap() {
  local zram_mb=$(( (RAM_MB * ZRAM_PCT) / 100 ))
  (( zram_mb < 256 )) && zram_mb=256

  cat >/usr/local/sbin/zram-autoscript-init <<EOF
#!/usr/bin/env bash
modprobe zram num_devices=1 2>/dev/null || exit 0
[[ -b /dev/zram0 ]] || exit 0
if grep -q "/dev/zram0" /proc/swaps 2>/dev/null; then
  exit 0
fi
echo 1 > /sys/block/zram0/reset 2>/dev/null || true
for algo in lz4 zstd lzo-rle; do
  if grep -qw "\$algo" /sys/block/zram0/comp_algorithm 2>/dev/null; then
    echo "\$algo" > /sys/block/zram0/comp_algorithm 2>/dev/null || true
    break
  fi
done
echo "${zram_mb}M" > /sys/block/zram0/disksize 2>/dev/null || exit 0
mkswap /dev/zram0 >/dev/null 2>&1 && swapon -p 100 /dev/zram0 >/dev/null 2>&1 || true
EOF
  chmod 0755 /usr/local/sbin/zram-autoscript-init

  cat >/etc/systemd/system/zram-autoscript.service <<'EOF'
[Unit]
Description=Autoscript Compressed ZRAM Swap Accelerator
DefaultDependencies=no
After=local-fs.target
Before=swap.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/zram-autoscript-init
ExecStop=/sbin/swapoff /dev/zram0

[Install]
WantedBy=swap.target multi-user.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now zram-autoscript.service >/dev/null 2>&1 || /usr/local/sbin/zram-autoscript-init || true

  # Ensure disk swap has lower priority (10) than ZRAM (100) so hot pages stay in compressed RAM
  if [[ -f /swapfile ]] && ! grep -q "/swapfile" /proc/swaps 2>/dev/null; then
    chmod 600 /swapfile 2>/dev/null || true
    swapon -p 10 /swapfile >/dev/null 2>&1 || true
  fi
  log_ok "ZRAM compressed memory active (${zram_mb} MB @ priority 100)."
}

# ---------------------------------------------------------------------------
# 4. Extreme Kernel Sysctl & Conntrack Tuning + OS Security Hardening
# ---------------------------------------------------------------------------
apply_extreme_sysctl() {
  modprobe tcp_bbr >/dev/null 2>&1 || true
  modprobe nf_conntrack >/dev/null 2>&1 || true

  mkdir -p /etc/sysctl.d /etc/modules-load.d
  cat >/etc/modules-load.d/autoscript.conf <<'EOF'
tcp_bbr
nf_conntrack
zram
EOF

  cat >/etc/sysctl.d/99-autoscript-extreme.conf <<EOF
# ============================================================================
# Autoscript v5.6.1 Extreme Enterprise Linux 9 & 10 Kernel Tuning (${TIER})
# ============================================================================

# --- Forwarding & BBR Congestion Control ---
net.ipv4.ip_forward = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384

# --- High-Density Socket Buffers & Backlogs ---
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 32768
net.core.optmem_max = 65536
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.rmem_max = ${TCP_BUF_MAX}
net.core.wmem_max = ${TCP_BUF_MAX}
net.ipv4.tcp_rmem = 4096 32768 ${TCP_BUF_MAX}
net.ipv4.tcp_wmem = 4096 32768 ${TCP_BUF_MAX}
net.ipv4.tcp_mem = ${TCP_MEM}
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# --- Ephemeral Ports, TIME_WAIT & Dead Mobile Socket Reclamation ---
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_max_syn_backlog = 32768
net.ipv4.tcp_max_tw_buckets = 65536
net.ipv4.tcp_max_orphans = ${ORPHANS_MAX}
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syncookies = 1

# --- Netfilter Conntrack High-Concurrency Table ---
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 1800
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# --- Virtual Memory, ZRAM & File Descriptor Ceiling ---
fs.file-max = 1048576
fs.nr_open = 1048576
vm.swappiness = ${SWAPPINESS}
vm.page-cluster = 0
vm.vfs_cache_pressure = 50
vm.dirty_background_ratio = 5
vm.dirty_ratio = 10
vm.overcommit_memory = 1
vm.min_free_kbytes = 16384

# --- Kernel Anti-Spoofing & Exploit Hardening ---
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.suid_dumpable = 0
EOF

  sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-autoscript-extreme.conf >/dev/null 2>&1 || true

  # Raise conntrack hashsize dynamically to match nf_conntrack_max / 4
  if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo $(( CONNTRACK_MAX / 4 )) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
  fi

  # System-wide PAM, shell & systemd ulimit ceilings (>= 65535 NPROC / 1048576 NOFILE, 0 core-dump stall)
  mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d /etc/systemd/user.conf.d /etc/profile.d
  cat >/etc/security/limits.d/99-autoscript.conf <<'EOF'
*    soft nofile  1048576
*    hard nofile  1048576
root soft nofile  1048576
root hard nofile  1048576
*    soft nproc   65535
*    hard nproc   65535
root soft nproc   unlimited
root hard nproc   unlimited
*    soft memlock unlimited
*    hard memlock unlimited
root soft memlock unlimited
root hard memlock unlimited
*    soft fsize   unlimited
*    hard fsize   unlimited
*    soft data    unlimited
*    hard data    unlimited
*    soft stack   unlimited
*    hard stack   unlimited
*    soft core    0
*    hard core    0
root soft core    0
root hard core    0
EOF

  cat >/etc/profile.d/99-autoscript-ulimit.sh <<'EOF'
# Autoscript Enterprise Shell ulimit Guard
ulimit -n 1048576 2>/dev/null || ulimit -n 65535 2>/dev/null || true
ulimit -u 65535 2>/dev/null || true
ulimit -c 0 2>/dev/null || true
ulimit -l unlimited 2>/dev/null || true
ulimit -f unlimited 2>/dev/null || true
EOF
  chmod 0644 /etc/profile.d/99-autoscript-ulimit.sh

  cat >/etc/systemd/system.conf.d/99-autoscript-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1048576
DefaultLimitNPROC=65535
DefaultLimitMEMLOCK=infinity
DefaultLimitFSIZE=infinity
DefaultLimitDATA=infinity
DefaultLimitSTACK=infinity
DefaultLimitAS=infinity
DefaultLimitCORE=0
DefaultTasksMax=infinity
EOF
  cp -f /etc/systemd/system.conf.d/99-autoscript-limits.conf /etc/systemd/user.conf.d/99-autoscript-limits.conf 2>/dev/null || true

  log_ok "Kernel sysctl, BBR, conntrack (${CONNTRACK_MAX}), and full ulimit ceilings (NOFILE=1048576, NPROC=65535, CORE=0, MEMLOCK=infinity) applied."
}

# ---------------------------------------------------------------------------
# 5. Go Runtime Memory Bounds (GOMEMLIMIT / GOGC) & Squid Zero-Cache Lock
# ---------------------------------------------------------------------------
apply_daemon_memory_caps() {
  # Xray memory cap + ray buffer optimization + full ulimit & zero-downtime resilience
  mkdir -p /etc/systemd/system/xray.service.d
  cat >/etc/systemd/system/xray.service.d/10-memory-tuning.conf <<EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Environment="GOMEMLIMIT=${XRAY_MEMLIMIT}"
Environment="GOGC=${XRAY_GOGC}"
Environment="XRAY_RAY_BUFFER_SIZE=${XRAY_BUF_SIZE}"
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity
Restart=always
RestartSec=1s
OOMScoreAdjust=-500
EOF

  # API Server memory cap, OOM killer immunity, full ulimit & zero-downtime resilience
  mkdir -p /etc/systemd/system/api-server.service.d
  cat >/etc/systemd/system/api-server.service.d/10-memory-tuning.conf <<EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Environment="GOMEMLIMIT=${API_MEMLIMIT}"
Environment="GOGC=${API_GOGC}"
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity
Restart=always
RestartSec=1s
OOMScoreAdjust=-900
EOF

  # SSH-WS proxy memory cap, full ulimit & resilience
  mkdir -p /etc/systemd/system/ssh-ws.service.d
  cat >/etc/systemd/system/ssh-ws.service.d/10-memory-tuning.conf <<EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Environment="GOMEMLIMIT=${SSHWS_MEMLIMIT}"
Environment="GOGC=${API_GOGC}"
LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity
Restart=always
RestartSec=1s
EOF

  # Enforce full ulimit (>= 65535 NPROC, 1048576 NOFILE, 0 CORE, infinity MEMLOCK/FSIZE/AS)
  # across ALL tunnel, proxy, DNS, OpenVPN, Squid, and quota daemons
  local svc_unit
  for svc_unit in \
    dropbear.service \
    sshd.service \
    nginx.service \
    haproxy.service \
    squid.service \
    noobzvpns.service \
    slowdns.service \
    dnsmasq.service \
    openvpn-server@.service \
    quota-ssh.service \
    quota.service \
    quota-trojan.service \
    quota-vmess.service \
    limit-ip-vless.service \
    limit-ip-trojan.service \
    limit-ip-vmess.service; do
    mkdir -p "/etc/systemd/system/${svc_unit}.d"
    local extra_runtime=""
    if [[ "$svc_unit" == "haproxy.service" ]]; then
      extra_runtime="RuntimeDirectory=haproxy
RuntimeDirectoryMode=0755
"
    fi
    cat >"/etc/systemd/system/${svc_unit}.d/10-ulimit-resilience.conf" <<UEOF
[Unit]
StartLimitIntervalSec=0

[Service]
${extra_runtime}LimitNOFILE=1048576
LimitNPROC=65535
LimitMEMLOCK=infinity
LimitFSIZE=infinity
LimitDATA=infinity
LimitSTACK=infinity
LimitAS=infinity
LimitCORE=0
TasksMax=infinity
UEOF
  done

  # Optimize Squid to zero disk/object cache & strict VPS-only destination ACL (anti-open-proxy!)
  if [[ -f /etc/squid/squid.conf ]]; then
    local myip domain
    myip=$(hostname -I 2>/dev/null | awk '{print $1}')
    domain=$(cat /etc/xray/domain 2>/dev/null | tr -d '[:space:]')
    cat >/etc/squid/squid.conf <<EOF
# Autoscript v5.6.1 Hardened & Low-Memory Squid Configuration
acl to_vps_ip dst 127.0.0.1/32
$( [[ -n "$myip" ]] && echo "acl to_vps_ip dst ${myip}/32" )
$( [[ -n "$domain" && "$domain" != "notset" ]] && echo "acl to_vps_dom dstdomain ${domain}" )

acl Safe_ports port 22 80 109 143 443 3303 8080 8443 8585 8888 1194
acl SSL_ports port 22 109 143 443 3303 8443 8585

http_access deny !Safe_ports
http_access allow localhost manager
http_access deny manager
http_access allow to_vps_ip
$( [[ -n "$domain" && "$domain" != "notset" ]] && echo "http_access allow to_vps_dom" )
http_access deny all

http_port 3128
max_filedescriptors 65535
cache deny all
cache_mem 8 MB
maximum_object_size 0 KB
access_log none
cache_store_log none
logfile_rotate 0
via off
forwarded_for delete
httpd_suppress_version_string on
coredump_dir /var/spool/squid
EOF
    systemctl reload-or-restart squid >/dev/null 2>&1 || true
  fi

  systemctl daemon-reload >/dev/null 2>&1 || true
  log_ok "Daemon memory bounds applied (Xray=${XRAY_MEMLIMIT}, API=${API_MEMLIMIT}, Squid=8MB zero-cache & anti-open-proxy)."
}

# ---------------------------------------------------------------------------
# 6. Local Lightweight DNS Cache + Query/Reply Map for Live Domain Sniffing
# ---------------------------------------------------------------------------
setup_dns_domain_tracker() {
  if command -v dnsmasq >/dev/null 2>&1 || dnf install -y dnsmasq >/dev/null 2>&1; then
    mkdir -p /etc/dnsmasq.d /var/log
    touch /var/log/autoscript-dns.log
    chmod 640 /var/log/autoscript-dns.log
    cat >/etc/dnsmasq.d/autoscript-cache.conf <<'EOF'
listen-address=127.0.0.1
port=5353
bind-interfaces
no-resolv
server=1.1.1.1
server=8.8.8.8
cache-size=10000
min-cache-ttl=60
log-queries
log-facility=/var/log/autoscript-dns.log
EOF
    if command -v chcon >/dev/null 2>&1; then
      chcon -t dnsmasq_var_log_t /var/log/autoscript-dns.log >/dev/null 2>&1 || true
    fi
    systemctl enable --now dnsmasq >/dev/null 2>&1 || true
  fi
}

trim_el9_bloat
setup_zram_and_swap
apply_extreme_sysctl
apply_daemon_memory_caps
setup_dns_domain_tracker

if [[ "$QUIET" == "--json" ]]; then
  zram_active="false"
  grep -q "/dev/zram0" /proc/swaps 2>/dev/null && zram_active="true"
  bbr_cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
  ct_max=$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo "0")
  printf '{"tier":"%s","cpu_cores":%d,"ram_mb":%d,"zram_active":%s,"tcp_cc":"%s","conntrack_max":%s,"xray_memlimit":"%s","api_memlimit":"%s"}\n' \
    "$TIER" "$CPU_CORES" "$RAM_MB" "$zram_active" "$bbr_cur" "${ct_max:-0}" "$XRAY_MEMLIMIT" "$API_MEMLIMIT"
  exit 0
fi

log_ok "${OS_PRETTY} Extreme Optimization [${TIER}] completed!"
if [[ "$QUIET" != "--quiet" && -t 0 && "${2:-}" == "--menu" ]]; then
  echo ""
  read -n 1 -s -r -p " Press any key to return..."
fi
exit 0
