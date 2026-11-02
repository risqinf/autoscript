#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Hardened Dropbear SSH Manager (Prebuilt 2019.78 + Multi-Version)
# Supported OS: Rocky Linux 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10
# Version: 5.6.0
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
[[ -f /usr/local/sbin/lib/common.sh ]] && . /usr/local/sbin/lib/common.sh

require_root

BIGreen='\033[1;92m'
BIRed='\033[1;91m'
BIYellow='\033[1;93m'
BIWhite='\033[1;97m'

DROPBEAR_BIN="/usr/sbin/dropbear"
DROPBEAR_KEY_BIN="/usr/bin/dropbearkey"
DROPBEAR_CONFIG="/etc/dropbear"
DROPBEAR_URL="https://matt.ucc.asn.au/dropbear/releases"
REPO_OWNER="risqinf"
REPO_NAME="autoscript"

clear
ui_header "DROPBEAR SSH MANAGER"
echo -e " Current: ${GREEN}$(/usr/sbin/dropbear -V 2>&1 || echo 'Not installed')${NC}"
ui_rule
ui_opt 1 "Version 2019.78  (Prebuilt Hardened - Instant Install) [Recommended]"
ui_opt 2 "Version 2018.76  (Source Build - Hardened)"
ui_opt 3 "Version 2020.81  (Source Build - Hardened)"
ui_opt 4 "Version 2022.82  (Source Build - Hardened)"
ui_opt 5 "Version 2024.86  (Source Build - Hardened)"
ui_rule
ui_opt 0 "Back to Menu"
ui_foot
read -rp " Select menu [Default: 1] : " opt
[[ -z "$opt" ]] && opt="1"
echo -e ""

case "$opt" in
  1) clear ; DROPBEAR_VERSION="2019.78" ;;
  2) clear ; DROPBEAR_VERSION="2018.76" ;;
  3) clear ; DROPBEAR_VERSION="2020.81" ;;
  4) clear ; DROPBEAR_VERSION="2022.82" ;;
  5) clear ; DROPBEAR_VERSION="2024.86" ;;
  0|x|X) clear ; menu ; exit 0 ;;
  *) err "Invalid option." ; sleep 1 ; exec "$0" ;;
esac

install_prebuilt_dropbear_2019() {
  local arch_label=""
  case "$(uname -m)" in
    x86_64|amd64)  arch_label="linux-amd64" ;;
    aarch64|arm64) arch_label="linux-arm64" ;;
    *) return 1 ;;
  esac

  local archive_name="dropbear-2019.78-${arch_label}.tar.gz"
  local sha_name="dropbear-2019.78-${arch_label}.sha256"
  local tmp_dir
  tmp_dir="$(mktemp -d /tmp/dropbear-prebuilt.XXXXXX)"
  chmod 700 "$tmp_dir"

  local -a sources=(
    "/usr/local/share/autoscript/bin/${archive_name}|/usr/local/share/autoscript/bin/${sha_name}"
    "https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${archive_name}|https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/latest/download/${sha_name}"
    "https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/bin/${archive_name}|https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/main/bin/${sha_name}"
  )

  local pair src_arc src_sha exp_hash act_hash
  for pair in "${sources[@]}"; do
    src_arc="${pair%%|*}"
    src_sha="${pair#*|}"
    rm -f "${tmp_dir}/${archive_name}" "${tmp_dir}/${sha_name}"

    if [[ "$src_arc" == http* ]]; then
      info "Downloading prebuilt hardened Dropbear 2019.78 (${arch_label})..."
      curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 60 \
        -o "${tmp_dir}/${archive_name}" "$src_arc" 2>/dev/null || continue
      curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 30 \
        -o "${tmp_dir}/${sha_name}" "$src_sha" 2>/dev/null || continue
    else
      [[ -s "$src_arc" && -s "$src_sha" ]] || continue
      cp -f "$src_arc" "${tmp_dir}/${archive_name}"
      cp -f "$src_sha" "${tmp_dir}/${sha_name}"
    fi

    exp_hash=$(awk '{print $1; exit}' "${tmp_dir}/${sha_name}" | tr -d '[:space:]')
    act_hash=$(sha256sum "${tmp_dir}/${archive_name}" | awk '{print $1}')
    if [[ -z "$exp_hash" || "$exp_hash" != "$act_hash" ]]; then
      warn "SHA-256 verification mismatch on ${src_arc}; trying fallback..."
      continue
    fi

    mkdir -p "${tmp_dir}/extract"
    if tar -xzf "${tmp_dir}/${archive_name}" -C "${tmp_dir}/extract" 2>/dev/null; then
      if (cd "${tmp_dir}/extract" && [[ -s SHA256SUMS ]] && sha256sum -c SHA256SUMS >/dev/null 2>&1) && \
         [[ -f "${tmp_dir}/extract/dropbear" && -f "${tmp_dir}/extract/dropbearkey" ]]; then
        install -m 0755 "${tmp_dir}/extract/dropbear" "$DROPBEAR_BIN"
        install -m 0755 "${tmp_dir}/extract/dropbearkey" "$DROPBEAR_KEY_BIN"
        ln -sf "$DROPBEAR_KEY_BIN" /usr/sbin/dropbearkey
        mkdir -p /usr/local/share/autoscript/bin
        cp -f "${tmp_dir}/${archive_name}" "/usr/local/share/autoscript/bin/${archive_name}" 2>/dev/null || true
        cp -f "${tmp_dir}/${sha_name}" "/usr/local/share/autoscript/bin/${sha_name}" 2>/dev/null || true
        rm -rf "$tmp_dir"
        ok "Prebuilt Hardened Dropbear 2019.78 SHA-256 verified & installed!"
        return 0
      fi
    fi
  done

  rm -rf "$tmp_dir"
  return 1
}

clear
ui_header "INSTALLING DROPBEAR ${DROPBEAR_VERSION}"

systemctl stop dropbear >/dev/null 2>&1 || true
if [[ -f "$DROPBEAR_BIN" ]]; then
  cp -f "$DROPBEAR_BIN" /usr/sbin/dropbear.bak 2>/dev/null || true
fi

INSTALLED_OK=0
if [[ "$DROPBEAR_VERSION" == "2019.78" ]]; then
  if install_prebuilt_dropbear_2019; then
    INSTALLED_OK=1
  else
    warn "Prebuilt binary unavailable; falling back to hardened source build..."
  fi
fi

if [[ "$INSTALLED_OK" -ne 1 ]]; then
  info "Installing build toolchain for Dropbear ${DROPBEAR_VERSION}..."
  dnf groupinstall "Development Tools" -y >/dev/null 2>&1 || dnf install -y gcc make >/dev/null 2>&1
  dnf install -y zlib-devel libxcrypt-devel curl bzip2 >/dev/null 2>&1

  BUILD_DIR=$(mktemp -d /tmp/dropbear-build.XXXXXX)
  chmod 700 "$BUILD_DIR"
  cd "$BUILD_DIR" || exit 1

  info "Downloading Dropbear ${DROPBEAR_VERSION} (TLSv1.2+ Verified)..."
  curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 -o dropbear.tar.bz2 "$DROPBEAR_URL/dropbear-$DROPBEAR_VERSION.tar.bz2" || \
    curl -fsSL --proto '=https' --tlsv1.2 --max-time 60 -o dropbear.tar.bz2 "https://dropbear.nl/mirror/releases/dropbear-$DROPBEAR_VERSION.tar.bz2"

  if [[ ! -s "dropbear.tar.bz2" ]] || ! bzip2 -t dropbear.tar.bz2 2>/dev/null; then
    cd /root || cd /
    rm -rf "$BUILD_DIR"
    [[ -f /usr/sbin/dropbear.bak ]] && cp -f /usr/sbin/dropbear.bak "$DROPBEAR_BIN"
    systemctl start dropbear >/dev/null 2>&1 || true
    err "Download or archive verification failed."
    ui_back
    menu
    exit 1
  fi

  if [[ "$DROPBEAR_VERSION" == "2019.78" ]]; then
    if ! echo "525965971272270995364a0eb01f35180d793182e63dd0b0c3eb0292291644a4  dropbear.tar.bz2" | sha256sum -c - >/dev/null 2>&1; then
      cd /root || cd /
      rm -rf "$BUILD_DIR"
      [[ -f /usr/sbin/dropbear.bak ]] && cp -f /usr/sbin/dropbear.bak "$DROPBEAR_BIN"
      systemctl start dropbear >/dev/null 2>&1 || true
      err "Dropbear 2019.78 SHA-256 verification failed!"
      ui_back
      menu
      exit 1
    fi
  fi

  tar -xjf dropbear.tar.bz2
  cd "dropbear-$DROPBEAR_VERSION" || { rm -rf "$BUILD_DIR"; exit 1; }

  cat > localoptions.h <<'EOF'
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
EOF

  info "Compiling hardened Dropbear ${DROPBEAR_VERSION}..."
  if CFLAGS="-Os -fcommon -fstack-protector-strong" ./configure --prefix=/usr --sysconfdir=/etc/dropbear --disable-pam --disable-wtmp --disable-lastlog && \
     make -j"$(nproc 2>/dev/null || echo 1)" PROGRAMS="dropbear dropbearkey"; then
    install -m 0755 dropbear "$DROPBEAR_BIN"
    install -m 0755 dropbearkey "$DROPBEAR_KEY_BIN"
    ln -sf "$DROPBEAR_KEY_BIN" /usr/sbin/dropbearkey
    ok "Compilation succeeded."
  else
    cd /root || cd /
    rm -rf "$BUILD_DIR"
    [[ -f /usr/sbin/dropbear.bak ]] && cp -f /usr/sbin/dropbear.bak "$DROPBEAR_BIN"
    systemctl start dropbear >/dev/null 2>&1 || true
    err "Compilation failed; previous Dropbear binary restored."
    ui_back
    menu
    exit 1
  fi

  cd /root || cd /
  rm -rf "$BUILD_DIR"
fi

mkdir -p "$DROPBEAR_CONFIG"
chmod 700 "$DROPBEAR_CONFIG"
[[ -s /etc/dropbear/dropbear_rsa_host_key ]] || "$DROPBEAR_KEY_BIN" -t rsa -s 2048 -f /etc/dropbear/dropbear_rsa_host_key >/dev/null 2>&1
[[ -s /etc/dropbear/dropbear_ecdsa_host_key ]] || "$DROPBEAR_KEY_BIN" -t ecdsa -f /etc/dropbear/dropbear_ecdsa_host_key >/dev/null 2>&1
chmod 600 /etc/dropbear/dropbear_*_host_key 2>/dev/null || true

cat >/etc/systemd/system/dropbear.service <<'EOF'
[Unit]
Description=Dropbear Hardened SSH Server
After=network.target rsyslog.service
StartLimitIntervalSec=0

[Service]
Type=simple
KillMode=process
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

systemctl daemon-reload
if systemctl enable --now dropbear >/dev/null 2>&1 && systemctl restart dropbear; then
  ok "Dropbear service active on ports 109 & 143."
else
  err "Failed to start Dropbear service."
fi

ui_rule
echo -e " Installed : ${BIGreen}$("$DROPBEAR_BIN" -V 2>&1)${NC}"
ui_foot
ui_back
menu
