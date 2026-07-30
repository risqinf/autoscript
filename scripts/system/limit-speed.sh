#!/usr/bin/env bash
#
# limit-speed.sh - VPS Bandwidth Speed Limiter
# Full bidirectional (inbound + outbound) traffic shaping for tunneling
#
# Supported OS:
#   - Debian 10, 11, 12, 13
#   - Ubuntu 20.04 LTS - 26.04 LTS
#   - Rocky Linux 9, 10
#
# Usage:
#   sudo limit-speed                   # Interactive menu
#   sudo limit-speed --apply           # Apply saved config (systemd)
#   sudo limit-speed --stop            # Remove tc rules (keep config)
#   sudo limit-speed --cleanup         # Remove everything
#   sudo limit-speed --status          # Show current status
#   sudo limit-speed --speedtest       # Run speed test
#   sudo limit-speed --help            # Show help
#

set -euo pipefail
trap _exit INT QUIT TERM

# ═══════════════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════════════

readonly CONFIG_FILE="/etc/limit-speed.conf"
readonly IFB_DEV="ifb0"
readonly SERVICE_NAME="limit-speed"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly SCRIPT_VERSION="1.4.0"
readonly SPEEDTEST_DIR="/tmp/limit-speed-speedtest"

# ═══════════════════════════════════════════════════════════════════════════════
# Colors (use $'...' for actual escape characters)
# ═══════════════════════════════════════════════════════════════════════════════

R=$'\033[0;31m'
G=$'\033[0;32m'
Y=$'\033[1;33m'
C=$'\033[0;36m'
B=$'\033[1m'
D=$'\033[2m'
N=$'\033[0m'

# ═══════════════════════════════════════════════════════════════════════════════
# Globals
# ═══════════════════════════════════════════════════════════════════════════════

OS_ID=""
OS_VERSION=""
OS_NAME=""
IFACE=""
UPLOAD_RATE=""
DOWNLOAD_RATE=""
UPLOAD_LABEL=""
DOWNLOAD_LABEL=""
SELECTED_RATE=""
SELECTED_LABEL=""

# ═══════════════════════════════════════════════════════════════════════════════
# Logging (use %b to interpret escape sequences in arguments)
# ═══════════════════════════════════════════════════════════════════════════════

ok()    { printf " ${G}[✓]${N} %b\n" "$*"; }
warn()  { printf " ${Y}[!]${N} %b\n" "$*"; }
err()   { printf " ${R}[✗]${N} %b\n" "$*"; }
step()  { printf " ${C}[→]${N} %b\n" "$*"; }
info()  { printf " ${C}[i]${N} %b\n" "$*"; }
line()  { printf "${D} ────────────────────────────────────────────────────────${N}\n"; }
pause() { echo ""; read -rp " Tekan [Enter] untuk kembali..."; }

_exit() {
    echo ""
    err "Script terminated."
    [[ -n "${IFACE:-}" ]] && cleanup_tc 2>/dev/null || true
    cleanup_speedtest
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# Banner
# ═══════════════════════════════════════════════════════════════════════════════

banner() {
    clear
    echo -e "${C}"
    cat << 'EOF'
 ╔═══════════════════════════════════════════════════════╗
 ║           VPS Bandwidth Speed Limiter                 ║
 ║     Full Inbound + Outbound Traffic Shaping           ║
 ║                  For Tunneling                        ║
 ╚═══════════════════════════════════════════════════════╝
EOF
    echo -e "${N}"
    echo -e "  ${D}v${SCRIPT_VERSION}${N}"
    echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# Root Check
# ═══════════════════════════════════════════════════════════════════════════════

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Harus dijalankan sebagai root!"
        echo -e "  Gunakan: ${Y}sudo $(basename "$0")${N}"
        exit 1
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# OS Detection
# ═══════════════════════════════════════════════════════════════════════════════

detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        err "/etc/os-release tidak ditemukan"
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID="${OS_ID,,}"
    OS_VERSION="${VERSION_ID:-}"
    OS_NAME="${PRETTY_NAME:-Unknown}"

    local pass=false
    case "$OS_ID" in
        debian)
            local v="${OS_VERSION%%.*}"
            [[ -n "$v" && "$v" -ge 10 && "$v" -le 13 ]] && pass=true
            ;;
        ubuntu)
            case "$OS_VERSION" in
                20.04|22.04|24.04|25.04|26.04) pass=true ;;
            esac
            ;;
        rocky)
            local v="${OS_VERSION%%.*}"
            [[ -n "$v" && "$v" -ge 9 && "$v" -le 10 ]] && pass=true
            ;;
    esac

    if [[ "$pass" != true ]]; then
        err "OS tidak didukung: $OS_NAME"
        err "Didukung: Debian 10-13 | Ubuntu 20.04-26.04 LTS | Rocky 9-10"
        exit 1
    fi

    ok "OS: ${B}${OS_NAME}${N}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Interface Detection
# ═══════════════════════════════════════════════════════════════════════════════

detect_iface() {
    IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$IFACE" ]] && IFACE=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{print $5}' | head -1)

    if [[ -z "$IFACE" ]]; then
        err "Tidak dapat mendeteksi network interface!"
        exit 1
    fi

    ok "Interface: ${B}${IFACE}${N}"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Dependencies
# ═══════════════════════════════════════════════════════════════════════════════

install_deps() {
    step "Memeriksa dependencies..."

    local cmd=""
    case "$OS_ID" in
        debian|ubuntu)
            apt-get update -qq 2>/dev/null || true
            cmd="apt-get install -y"
            ;;
        rocky) cmd="dnf install -y" ;;
    esac

    if ! command -v tc &>/dev/null; then
        warn "tc tidak ditemukan, menginstall..."
        $cmd iproute2 2>/dev/null || $cmd iproute 2>/dev/null || {
            err "Gagal install iproute2"
            exit 1
        }
        ok "iproute2 terinstall"
    fi

    if ! modprobe ifb numifbs=1 2>/dev/null; then
        warn "Module IFB tidak tersedia, mencoba install kernel extras..."
        case "$OS_ID" in
            debian|ubuntu) $cmd "linux-modules-extra-$(uname -r)" 2>/dev/null || true ;;
        esac
        modprobe ifb numifbs=1 2>/dev/null || {
            err "Module IFB gagal dimuat! Download limit tidak akan bekerja."
        }
    fi

    ok "Dependencies OK"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Config Persistence
# ═══════════════════════════════════════════════════════════════════════════════

save_config() {
    cat > "$CONFIG_FILE" <<EOF
# limit-speed config - $(date '+%Y-%m-%d %H:%M:%S')
IFACE="${IFACE}"
UPLOAD_RATE="${UPLOAD_RATE}"
DOWNLOAD_RATE="${DOWNLOAD_RATE}"
UPLOAD_LABEL="${UPLOAD_LABEL}"
DOWNLOAD_LABEL="${DOWNLOAD_LABEL}"
EOF
    chmod 600 "$CONFIG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Validation
# ═══════════════════════════════════════════════════════════════════════════════

validate_rate() {
    local rate="$1"
    [[ "$rate" == "nolimit" ]] && return 0
    [[ "$rate" =~ ^[0-9]+(kbit|mbit|gbit)$ ]] || return 1
}

validate_iface() {
    local iface="$1"
    [[ "$iface" =~ ^[a-zA-Z0-9._:-]+$ ]] || return 1
    ip link show "$iface" &>/dev/null || return 1
}

load_config() {
    [[ ! -f "$CONFIG_FILE" ]] && return 1

    local line key value
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^([A-Z_]+)=\"([^\"]*)\"$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$key" in
                IFACE)          IFACE="$value" ;;
                UPLOAD_RATE)    UPLOAD_RATE="$value" ;;
                DOWNLOAD_RATE)  DOWNLOAD_RATE="$value" ;;
                UPLOAD_LABEL)   UPLOAD_LABEL="$value" ;;
                DOWNLOAD_LABEL) DOWNLOAD_LABEL="$value" ;;
                *) err "Config key tidak dikenal: $key"; return 1 ;;
            esac
        else
            err "Format config tidak valid: $line"
            return 1
        fi
    done < "$CONFIG_FILE"

    if ! validate_iface "${IFACE:-}"; then
        err "IFACE tidak valid dalam config"
        return 1
    fi
    if ! validate_rate "${UPLOAD_RATE:-}"; then
        err "UPLOAD_RATE tidak valid dalam config"
        return 1
    fi
    if ! validate_rate "${DOWNLOAD_RATE:-}"; then
        err "DOWNLOAD_RATE tidak valid dalam config"
        return 1
    fi
    return 0
}

remove_config() {
    rm -f "$CONFIG_FILE"
}

# ═══════════════════════════════════════════════════════════════════════════════
# Traffic Control
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_tc() {
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
    tc qdisc del dev "$IFB_DEV" root 2>/dev/null || true
    ip link set dev "$IFB_DEV" down 2>/dev/null || true
    rmmod ifb 2>/dev/null || true
}

calc_r2q() {
    local rate="$1"
    awk -v rate="$rate" 'BEGIN {
        rate = tolower(rate)
        if (match(rate, /gbit$/)) { r = substr(rate, 1, RSTART-1) * 1000000000 }
        else if (match(rate, /mbit$/)) { r = substr(rate, 1, RSTART-1) * 1000000 }
        else if (match(rate, /kbit$/)) { r = substr(rate, 1, RSTART-1) * 1000 }
        else { r = rate + 0 }
        r2q = int(r / 8 / 1500)
        if (r2q < 1) r2q = 1
        print r2q
    }'
}

calc_burst() {
    local rate="$1"
    awk -v rate="$rate" 'BEGIN {
        rate = tolower(rate)
        if (match(rate, /gbit$/)) { r = substr(rate, 1, RSTART-1) * 1000000000 }
        else if (match(rate, /mbit$/)) { r = substr(rate, 1, RSTART-1) * 1000000 }
        else if (match(rate, /kbit$/)) { r = substr(rate, 1, RSTART-1) * 1000 }
        else { r = rate + 0 }
        burst = int(r / 8 / 1000)
        if (burst < 15000) burst = 15000
        print burst
    }'
}

calc_critical_rate() {
    local rate="$1"
    awk -v rate="$rate" 'BEGIN {
        rate = tolower(rate)
        if (match(rate, /gbit$/)) { r = substr(rate, 1, RSTART-1) * 1000 }
        else if (match(rate, /mbit$/)) { r = substr(rate, 1, RSTART-1) + 0 }
        else if (match(rate, /kbit$/)) { r = substr(rate, 1, RSTART-1) / 1000 }
        else { r = rate + 0 }
        if (r >= 10) critical = 10
        else critical = 1
        printf "%dmbit", critical
    }'
}

apply_egress() {
    local rate="$1"
    [[ "$rate" == "nolimit" ]] && return 0
    validate_rate "$rate" || { err "Rate tidak valid: $rate"; return 1; }

    step "Egress (Upload): ${B}${rate}${N} → ${IFACE}"

    local r2q burst critical_rate
    r2q=$(calc_r2q "$rate")
    burst=$(calc_burst "$rate")
    critical_rate=$(calc_critical_rate "$rate")

    tc qdisc add dev "$IFACE" root handle 1: htb default 20 r2q "$r2q" || return 1
    tc class add dev "$IFACE" parent 1: classid 1:1 htb rate "$rate" ceil "$rate" burst "$burst" || return 1
    tc class add dev "$IFACE" parent 1:1 classid 1:10 htb rate "$critical_rate" ceil "$rate" burst "$burst" prio 0 quantum 1500 || return 1
    tc class add dev "$IFACE" parent 1:1 classid 1:20 htb rate "$rate" ceil "$rate" burst "$burst" prio 1 || return 1
    tc qdisc add dev "$IFACE" parent 1:10 handle 10: sfq perturb 10 || return 1
    tc qdisc add dev "$IFACE" parent 1:20 handle 20: sfq perturb 10 || return 1

    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip dport 22 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip sport 22 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip dport 53 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip sport 53 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip dport 67 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip dport 68 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 match ip protocol 1 0xff flowid 1:10 || return 1

    tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 match ip6 dport 22 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 match ip6 sport 22 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 match ip6 dport 53 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 match ip6 sport 53 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFACE" protocol ipv6 parent 1: prio 1 u32 match ip6 protocol 58 0xff flowid 1:10 2>/dev/null || true

    ok "Upload limit aktif: ${G}${rate}${N}"
}

apply_ingress() {
    local rate="$1"
    [[ "$rate" == "nolimit" ]] && return 0
    validate_rate "$rate" || { err "Rate tidak valid: $rate"; return 1; }

    step "Ingress (Download): ${B}${rate}${N} → ${IFB_DEV}"

    modprobe ifb numifbs=1 2>/dev/null || {
        err "Gagal memuat IFB module"
        return 1
    }

    ip link set dev "$IFB_DEV" up || {
        err "Gagal mengaktifkan IFB device"
        return 1
    }

    local r2q burst critical_rate
    r2q=$(calc_r2q "$rate")
    burst=$(calc_burst "$rate")
    critical_rate=$(calc_critical_rate "$rate")

    tc qdisc add dev "$IFB_DEV" root handle 1: htb default 20 r2q "$r2q" || return 1
    tc class add dev "$IFB_DEV" parent 1: classid 1:1 htb rate "$rate" ceil "$rate" burst "$burst" || return 1
    tc class add dev "$IFB_DEV" parent 1: classid 1:10 htb rate "$critical_rate" ceil "$rate" burst "$burst" prio 0 quantum 1500 || return 1
    tc class add dev "$IFB_DEV" parent 1: classid 1:20 htb rate "$rate" ceil "$rate" burst "$burst" prio 1 || return 1
    tc qdisc add dev "$IFB_DEV" parent 1:10 handle 10: sfq perturb 10 || return 1
    tc qdisc add dev "$IFB_DEV" parent 1:20 handle 20: sfq perturb 10 || return 1

    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip dport 22 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip sport 22 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip dport 53 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip sport 53 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip dport 67 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip dport 68 0xffff flowid 1:10 || return 1
    tc filter add dev "$IFB_DEV" protocol ip parent 1: prio 1 u32 match ip protocol 1 0xff flowid 1:10 || return 1

    tc filter add dev "$IFB_DEV" protocol ipv6 parent 1: prio 1 u32 match ip6 dport 22 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFB_DEV" protocol ipv6 parent 1: prio 1 u32 match ip6 sport 22 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFB_DEV" protocol ipv6 parent 1: prio 1 u32 match ip6 dport 53 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFB_DEV" protocol ipv6 parent 1: prio 1 u32 match ip6 sport 53 0xffff flowid 1:10 2>/dev/null || true
    tc filter add dev "$IFB_DEV" protocol ipv6 parent 1: prio 1 u32 match ip6 protocol 58 0xff flowid 1:10 2>/dev/null || true

    tc qdisc del dev "$IFACE" ingress 2>/dev/null || true
    tc qdisc add dev "$IFACE" handle ffff: ingress || return 1
    tc filter add dev "$IFACE" parent ffff: protocol ip u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB_DEV" || return 1
    tc filter add dev "$IFACE" parent ffff: protocol ipv6 u32 match u32 0 0 \
        action mirred egress redirect dev "$IFB_DEV" 2>/dev/null || true

    ok "Download limit aktif: ${G}${rate}${N}"
}

apply_all() {
    cleanup_tc

    if [[ "$UPLOAD_RATE" == "nolimit" && "$DOWNLOAD_RATE" == "nolimit" ]]; then
        echo ""
        ok "Kedua direction = No Limit, tidak ada shaping"
        return
    fi

    echo ""
    local rc=0
    if [[ "$UPLOAD_RATE" != "nolimit" ]]; then
        apply_egress "$UPLOAD_RATE" || rc=1
    fi
    if [[ "$DOWNLOAD_RATE" != "nolimit" ]]; then
        apply_ingress "$DOWNLOAD_RATE" || rc=1
    fi

    if [[ $rc -ne 0 ]]; then
        echo ""
        err "Gagal menerapkan limit! Membersihkan..."
        cleanup_tc
        return 1
    fi

    echo ""
    line
    ok "Traffic shaping aktif!"
    echo -e "  ${C}Interface :${N} ${IFACE}"
    echo -e "  ${C}Upload    :${N} ${G}${UPLOAD_LABEL}${N}"
    echo -e "  ${C}Download  :${N} ${G}${DOWNLOAD_LABEL}${N}"
    line
}

# ═══════════════════════════════════════════════════════════════════════════════
# System Info (from bench.sh)
# ═══════════════════════════════════════════════════════════════════════════════

get_arch() {
    local arch
    arch="$(uname -m)"
    case "${arch}" in
        x86_64|amd64)  echo "x64" ;;
        i?86)          echo "x86" ;;
        aarch64|arm64) echo "aarch64" ;;
        armv7*|armv8l) echo "arm" ;;
        *)             echo "${arch}" ;;
    esac
}

calc_size() {
    local raw="${1}"
    local num=1
    local unit="KB"

    if ! [[ ${raw} =~ ^[0-9]+$ ]]; then echo ""; return; fi
    if [[ "${raw}" -eq 0 ]]; then echo "0 KB"; return; fi

    if [[ "${raw}" -ge 1073741824 ]]; then num=1073741824; unit="TB"
    elif [[ "${raw}" -ge 1048576 ]]; then num=1048576; unit="GB"
    elif [[ "${raw}" -ge 1024 ]]; then num=1024; unit="MB"
    fi

    awk -v r="$raw" -v n="$num" -v u="$unit" 'BEGIN{printf "%.1f %s\n", r/n, u}'
}

show_system_info() {
    local cname cores freq ccache tram uram swap kern arch opsy load up tcpctrl

    cname=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')
    cores=$(awk -F: '/^processor/ {core++} END {print core}' /proc/cpuinfo)
    freq=$(awk -F'[ :]' '/cpu MHz/ {print $4;exit}' /proc/cpuinfo)
    ccache=$(awk -F: '/cache size/ {cache=$2} END {print cache}' /proc/cpuinfo | sed 's/^[ \t]*//;s/[ \t]*$//')

    tram=$(LANG=C free | awk '/Mem/ {print $2}')
    tram=$(calc_size "${tram}")
    uram=$(LANG=C free | awk '/Mem/ {print $3}')
    uram=$(calc_size "${uram}")

    swap=$(LANG=C free | awk '/Swap/ {print $2}')
    swap=$(calc_size "${swap}")

    up=$(awk '{a=$1/86400;b=($1%86400)/3600;c=($1%3600)/60} {printf("%d days, %d hour %d min\n",a,b,c)}' /proc/uptime)

    if command -v w &>/dev/null; then
        load=$(LANG=C w | head -1 | awk -F'load average:' '{print $2}' | sed 's/^[ \t]*//;s/[ \t]*$//')
    fi

    opsy=$(awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2}' /etc/os-release)
    arch=$(uname -m)
    kern=$(uname -r)
    tcpctrl=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)

    echo ""
    line
    echo -e " ${B}${C}SYSTEM INFO${N}"
    line
    echo -e "  ${C}OS             :${N} ${opsy}"
    echo -e "  ${C}Arch           :${N} ${arch}"
    echo -e "  ${C}Kernel         :${N} ${kern}"
    echo -e "  ${C}CPU            :${N} ${cname}"
    echo -e "  ${C}Cores          :${N} ${cores} @ ${freq} MHz"
    [[ -n "${ccache}" ]] && echo -e "  ${C}Cache          :${N} ${ccache}"
    echo -e "  ${C}RAM            :${N} ${G}${tram}${N} (${uram} Used)"
    echo -e "  ${C}Swap           :${N} ${swap}"
    echo -e "  ${C}Uptime         :${N} ${up}"
    [[ -n "${load}" ]] && echo -e "  ${C}Load Avg       :${N} ${load}"
    [[ -n "${tcpctrl}" ]] && echo -e "  ${C}TCP Ctrl       :${N} ${tcpctrl}"
    line
}

# ═══════════════════════════════════════════════════════════════════════════════
# Speed Test (adapted from bench.sh by Teddysun)
# ═══════════════════════════════════════════════════════════════════════════════

cleanup_speedtest() {
    rm -rf "${SPEEDTEST_DIR}" 2>/dev/null
}

install_speedtest_cli() {
    if [[ -e "${SPEEDTEST_DIR}/speedtest" ]]; then
        return 0
    fi

    step "Downloading speedtest CLI..."

    local sys_bit
    local sysarch
    sysarch="$(uname -m)"

    case "${sysarch}" in
        x86_64|amd64)     sys_bit="x86_64" ;;
        i386|i686)        sys_bit="i386" ;;
        armv8*|aarch64|arm64) sys_bit="aarch64" ;;
        armv7*|armv7l)    sys_bit="armhf" ;;
        *)                sys_bit="x86_64" ;;
    esac

    local url1 url2
    url1="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-${sys_bit}.tgz"
    url2="https://dl.lamp.sh/files/ookla-speedtest-1.2.0-linux-${sys_bit}.tgz"

    mkdir -p "${SPEEDTEST_DIR}"

    if ! wget --no-check-certificate -q -T15 -O "${SPEEDTEST_DIR}/speedtest.tgz" "${url1}" 2>/dev/null; then
        if ! wget --no-check-certificate -q -T15 -O "${SPEEDTEST_DIR}/speedtest.tgz" "${url2}" 2>/dev/null; then
            if ! curl -sL -m 15 -o "${SPEEDTEST_DIR}/speedtest.tgz" "${url1}" 2>/dev/null; then
                err "Gagal download speedtest CLI"
                return 1
            fi
        fi
    fi

    tar zxf "${SPEEDTEST_DIR}/speedtest.tgz" -C "${SPEEDTEST_DIR}" 2>/dev/null
    rm -f "${SPEEDTEST_DIR}/speedtest.tgz"

    if [[ ! -f "${SPEEDTEST_DIR}/speedtest" ]]; then
        err "Binary speedtest tidak ditemukan setelah extract"
        return 1
    fi

    if ! file "${SPEEDTEST_DIR}/speedtest" 2>/dev/null | grep -q "ELF"; then
        err "Binary speedtest bukan executable yang valid"
        rm -f "${SPEEDTEST_DIR}/speedtest"
        return 1
    fi

    chmod +x "${SPEEDTEST_DIR}/speedtest"

    ok "Speedtest CLI siap"
}

run_speedtest_single() {
    local server_id="${1}"
    local node_name="${2}"
    local logfile="${SPEEDTEST_DIR}/speedtest.log"

    if [[ -z "${server_id}" ]]; then
        if ! "${SPEEDTEST_DIR}/speedtest" --progress=no --accept-license --accept-gdpr >"${logfile}" 2>&1; then
            printf "  ${Y}%-20s${R}%-18s${N}\n" "${node_name}" "Test failed"
            return 1
        fi
    else
        if ! "${SPEEDTEST_DIR}/speedtest" --progress=no --server-id="${server_id}" --accept-license --accept-gdpr >"${logfile}" 2>&1; then
            printf "  ${Y}%-20s${R}%-18s${N}\n" "${node_name}" "Test failed"
            return 1
        fi
    fi

    local dl_speed up_speed latency
    dl_speed=$(awk '/Download/{print $3" "$4}' "${logfile}")
    up_speed=$(awk '/Upload/{print $3" "$4}' "${logfile}")
    latency=$(awk '/Latency/{print $3" "$4}' "${logfile}")

    if [[ -n "${dl_speed}" && -n "${up_speed}" ]]; then
        printf "  ${Y}%-20s${G}%-16s${R}%-16s${C}%-12s${N}\n" \
            "${node_name}" "↑ ${up_speed}" "↓ ${dl_speed}" "${latency}"
    else
        printf "  ${Y}%-20s${R}%-18s${N}\n" "${node_name}" "Parse failed"
        return 1
    fi
}

run_speedtest() {
    echo ""
    line
    echo -e " ${B}${C}SPEED TEST${N}"
    line
    printf "  ${B}%-20s%-16s%-16s%-12s${N}\n" "Node" "Upload" "Download" "Latency"
    line

    run_speedtest_single ''      'Nearest Server' || true
    run_speedtest_single '13623' 'Singapore, SG' || true
    run_speedtest_single '48463' 'Tokyo, JP'    || true
    run_speedtest_single '32155' 'Hong Kong, HK' || true

    line
}

run_all_tests() {
    show_system_info

    if install_speedtest_cli; then
        run_speedtest
    else
        warn "Speedtest CLI tidak tersedia, skip speed test"
    fi

    cleanup_speedtest
}

# ═══════════════════════════════════════════════════════════════════════════════
# Systemd Service
# ═══════════════════════════════════════════════════════════════════════════════

install_service() {
    cat > "$SERVICE_FILE" <<SVCEOF
[Unit]
Description=Limit Speed - Bandwidth Traffic Shaping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/sbin/modprobe ifb numifbs=1
ExecStart=/usr/local/sbin/limit-speed --apply
ExecStop=/usr/local/sbin/limit-speed --stop
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" 2>/dev/null
    ok "Systemd service aktif (auto-start setelah reboot)"
}

remove_service() {
    systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════════
# CLI Commands
# ═══════════════════════════════════════════════════════════════════════════════

cmd_apply() {
    if ! load_config; then
        err "Config tidak ditemukan. Jalankan setup dulu."
        exit 1
    fi

    if ! ip link show "$IFACE" &>/dev/null; then
        warn "Interface '$IFACE' tidak ditemukan, deteksi ulang..."
        IFACE=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
        [[ -z "$IFACE" ]] && { err "Interface tidak ditemukan!"; exit 1; }
        info "Menggunakan: $IFACE"
    fi

    apply_all
}

cmd_stop() {
    if load_config 2>/dev/null; then
        if ip link show "$IFACE" &>/dev/null; then
            cleanup_tc
            ok "TC rules dihapus (config tersimpan)"
        fi
    fi
}

cmd_cleanup() {
    if load_config 2>/dev/null && ip link show "$IFACE" &>/dev/null; then
        cleanup_tc
    fi
    remove_config
    remove_service
    ok "Semua limit dan config dihapus"
}

cmd_status() {
    echo ""
    line
    echo -e " ${B}${C}STATUS LIMIT${N}"
    line

    local saved_iface="${IFACE:-}"
    local iface="$saved_iface"
    if load_config 2>/dev/null; then
        [[ -z "$iface" ]] && iface="$IFACE"
        echo -e "  ${C}Interface  :${N} ${IFACE}"
        echo -e "  ${C}Upload     :${N} ${G}${UPLOAD_LABEL}${N}"
        echo -e "  ${C}Download   :${N} ${G}${DOWNLOAD_LABEL}${N}"
    else
        echo -e "  ${Y}Tidak ada config tersimpan${N}"
    fi
    IFACE="$saved_iface"

    [[ -z "$iface" ]] && iface=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
    [[ -z "$iface" ]] && iface="eth0"

    echo ""
    echo -e " ${B}${C}TC QDISC${N}"
    line

    echo -e "\n  ${C}Egress (${iface}):${N}"
    tc -s qdisc show dev "$iface" 2>/dev/null | sed 's/^/    /' || echo "    default"

    echo -e "\n  ${C}Ingress (${iface}):${N}"
    tc qdisc show dev "$iface" ingress 2>/dev/null | sed 's/^/    /' || echo "    none"

    echo -e "\n  ${C}IFB (${IFB_DEV}):${N}"
    tc qdisc show dev "$IFB_DEV" 2>/dev/null | sed 's/^/    /' || echo "    inactive"

    echo ""
    line
}

cmd_speedtest() {
    detect_iface
    run_all_tests
}

cmd_help() {
    cat << 'HELP'
 Usage:
   sudo limit-speed                   Interactive menu
   sudo limit-speed --apply           Apply saved config
   sudo limit-speed --stop            Remove tc rules (keep config)
   sudo limit-speed --cleanup         Remove everything
   sudo limit-speed --status          Show current status
   sudo limit-speed --speedtest       Run speed test
   sudo limit-speed --help            This help

 Supported OS:
   Debian 10, 11, 12, 13
   Ubuntu 20.04, 22.04, 24.04, 25.04, 26.04 LTS
   Rocky Linux 9, 10
HELP
}

# ═══════════════════════════════════════════════════════════════════════════════
# Interactive: Rate Selection
# ═══════════════════════════════════════════════════════════════════════════════

choose_rate() {
    local direction="$1"
    SELECTED_RATE=""
    SELECTED_LABEL=""

    echo ""
    echo -e " ${B}Pilih limit ${direction}:${N}"
    line
    echo -e "  ${G}[1]${N} 256 Mbps"
    echo -e "  ${G}[2]${N} 512 Mbps"
    echo -e "  ${G}[3]${N} 1 Gbps"
    echo -e "  ${G}[4]${N} 2 Gbps"
    echo -e "  ${G}[5]${N} 5 Gbps"
    echo -e "  ${G}[6]${N} 10 Gbps"
    echo -e "  ${G}[7]${N} 20 Gbps"
    echo -e "  ${G}[8]${N} No Limit"
    echo -e "  ${G}[9]${N} Custom (input manual)"
    line

    local choice
    read -rp " Pilih [1-9]: " choice

    case "$choice" in
        1) SELECTED_RATE="256mbit";  SELECTED_LABEL="256 Mbps" ;;
        2) SELECTED_RATE="512mbit";  SELECTED_LABEL="512 Mbps" ;;
        3) SELECTED_RATE="1gbit";    SELECTED_LABEL="1 Gbps" ;;
        4) SELECTED_RATE="2gbit";    SELECTED_LABEL="2 Gbps" ;;
        5) SELECTED_RATE="5gbit";    SELECTED_LABEL="5 Gbps" ;;
        6) SELECTED_RATE="10gbit";   SELECTED_LABEL="10 Gbps" ;;
        7) SELECTED_RATE="20gbit";   SELECTED_LABEL="20 Gbps" ;;
        8) SELECTED_RATE="nolimit";  SELECTED_LABEL="No Limit" ;;
        9) choose_custom ;;
        *) err "Pilihan tidak valid"; return 1 ;;
    esac

    return 0
}

choose_custom() {
    echo ""
    echo -e " ${B}Custom Rate:${N}"
    line
    echo -e "  ${G}[1]${N} Megabit (Mbps)"
    echo -e "  ${G}[2]${N} Gigabit (Gbps)"
    line

    local unit val
    read -rp " Unit [1-2]: " unit
    read -rp " Nilai: " val

    if [[ ! "$val" =~ ^[0-9]+$ ]] || [[ "$val" -le 0 ]]; then
        err "Nilai harus angka positif!"
        SELECTED_RATE=""
        SELECTED_LABEL=""
        return 1
    fi

    case "$unit" in
        1) SELECTED_RATE="${val}mbit"; SELECTED_LABEL="${val} Mbps" ;;
        2) SELECTED_RATE="${val}gbit"; SELECTED_LABEL="${val} Gbps" ;;
        *) err "Unit tidak valid"; SELECTED_RATE=""; SELECTED_LABEL=""; return 1 ;;
    esac
}

# ═══════════════════════════════════════════════════════════════════════════════
# Interactive: Set Limit
# ═══════════════════════════════════════════════════════════════════════════════

set_limit() {
    echo ""
    echo -e " ${B}${C}SET SPEED LIMIT${N}"
    line
    echo -e "  ${D}Interface: ${B}${IFACE}${N}"

    if ! choose_rate "Upload (Outbound)"; then return; fi
    UPLOAD_RATE="$SELECTED_RATE"
    UPLOAD_LABEL="$SELECTED_LABEL"

    if ! choose_rate "Download (Inbound)"; then return; fi
    DOWNLOAD_RATE="$SELECTED_RATE"
    DOWNLOAD_LABEL="$SELECTED_LABEL"

    apply_all
    save_config

    echo ""
    read -rp " Aktifkan auto-start setelah reboot? [y/N]: " ans
    if [[ "${ans,,}" == "y" ]]; then
        install_service
    fi
}

# ═══════════════════════════════════════════════════════════════════════════════
# Interactive: Remove Limits
# ═══════════════════════════════════════════════════════════════════════════════

remove_limits() {
    cleanup_tc
    remove_config
    remove_service
    echo ""
    ok "Semua limit dihapus! Traffic kembali unlimited."
}

# ═══════════════════════════════════════════════════════════════════════════════
# Main Menu
# ═══════════════════════════════════════════════════════════════════════════════

main_menu() {
    while true; do
        banner

        echo -e "  ${C}OS        :${N} ${OS_NAME}"
        echo -e "  ${C}Interface :${N} ${IFACE}"
        echo ""

        local saved_iface="$IFACE"
        if load_config 2>/dev/null; then
            echo -e "  ${C}Upload    :${N} ${G}${UPLOAD_LABEL:-N/A}${N}"
            echo -e "  ${C}Download  :${N} ${G}${DOWNLOAD_LABEL:-N/A}${N}"
        else
            echo -e "  ${Y}Status    : Tidak ada limit aktif${N}"
        fi
        IFACE="$saved_iface"

        echo ""
        line
        echo -e " ${B}MENU:${N}"
        echo -e "  ${G}[1]${N} Set Speed Limit"
        echo -e "  ${G}[2]${N} Show Current Limit"
        echo -e "  ${G}[3]${N} Remove All Limits"
        echo -e "  ${G}[4]${N} Speed Test (Cek bandwidth)"
        echo -e "  ${G}[5]${N} Exit"
        line

        local choice
        read -rp " Pilih [1-5]: " choice

        case "$choice" in
            1) set_limit;     pause ;;
            2) cmd_status;    pause ;;
            3) remove_limits; pause ;;
            4) run_all_tests; cleanup_speedtest; pause ;;
            5) echo ""; info "Selesai!"; exit 0 ;;
            *) err "Pilihan tidak valid"; pause ;;
        esac
    done
}

# ═══════════════════════════════════════════════════════════════════════════════
# Entry Point
# ═══════════════════════════════════════════════════════════════════════════════

main() {
    check_root

    case "${1:-}" in
        --apply)     cmd_apply;     exit 0 ;;
        --stop)      cmd_stop;      exit 0 ;;
        --cleanup)   cmd_cleanup;   exit 0 ;;
        --status)    cmd_status;    exit 0 ;;
        --speedtest) cmd_speedtest; exit 0 ;;
        --help|-h)   cmd_help;      exit 0 ;;
    esac

    banner
    detect_os
    install_deps
    detect_iface
    main_menu
}

main "$@"
