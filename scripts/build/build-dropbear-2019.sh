#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Reproducible Static Hardened Dropbear 2019.78 Builder
#              (musl + static libxcrypt YESCRYPT/$y$ & SHA-512/$6$ + SSRF guard)
# Compatible Targets: Rocky Linux 9-10, RHEL 9-10, AlmaLinux 9-10, Oracle Linux 9-10
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
set -euo pipefail

ARCH_LABEL="${1:-linux-amd64}"
OUT_DIR="${2:-$(pwd)/dist}"

DROPBEAR_VER="2019.78"
DROPBEAR_SHA256="525965971272270995364a0eb01f35180d793182e63dd0b0c3eb0292291644a4"
LIBXCRYPT_VER="4.4.36"
LIBXCRYPT_SHA256="e5e1f4caee0a01de2aee26e3138807d6d3ca2b8e67287966d1fefd65e1fd8943"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

if command -v apk >/dev/null 2>&1; then
  echo "[INFO] Installing Alpine static build toolchain..."
  apk add --no-cache \
    build-base autoconf automake libtool pkgconf \
    zlib-dev zlib-static curl ca-certificates \
    tar bzip2 xz perl python3 linux-headers file
fi

WORK_DIR="$(mktemp -d /tmp/dropbear-static-build.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
chmod 700 "$WORK_DIR"
cd "$WORK_DIR"

JOBS="$(nproc 2>/dev/null || echo 2)"

# ---------------------------------------------------------------------------
# 1. Download & Cryptographically Verify libxcrypt 4.4.36 (EL9 $6$ + EL10 $y$)
# ---------------------------------------------------------------------------
echo "[INFO] Downloading libxcrypt-${LIBXCRYPT_VER}..."
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 \
  -o "libxcrypt-${LIBXCRYPT_VER}.tar.xz" \
  "https://github.com/besser82/libxcrypt/releases/download/v${LIBXCRYPT_VER}/libxcrypt-${LIBXCRYPT_VER}.tar.xz"

echo "${LIBXCRYPT_SHA256}  libxcrypt-${LIBXCRYPT_VER}.tar.xz" | sha256sum -c -
tar -xJf "libxcrypt-${LIBXCRYPT_VER}.tar.xz"

pushd "libxcrypt-${LIBXCRYPT_VER}" >/dev/null
./configure \
  --prefix=/opt/xcrypt \
  --disable-shared \
  --enable-static \
  --enable-hashes=all \
  --enable-obsolete-api=no \
  --disable-xcrypt-compat-files \
  --disable-failure-tokens \
  --disable-werror \
  CFLAGS="-Os -fPIC -fstack-protector-strong"
make -j"$JOBS"
make install
popd >/dev/null

# Compile & run build-time verification for EL10 ($y$ YESCRYPT) & EL9 ($6$ SHA-512)
cat > xcrypt_selftest.c <<'EOF'
#include <stdio.h>
#include <string.h>
#include <crypt.h>

static int verify_prefix(const char *prefix, const char *pw) {
    char *setting = crypt_gensalt(prefix, 0, NULL, 0);
    if (!setting || setting[0] == '*') return 1;
    char *h1 = crypt(pw, setting);
    if (!h1 || h1[0] == '*') return 2;
    char saved[256];
    snprintf(saved, sizeof(saved), "%s", h1);
    char *h2 = crypt(pw, saved);
    if (!h2 || strcmp(saved, h2) != 0) return 3;
    return 0;
}

int main(void) {
    if (verify_prefix("$y$", "AutoscriptEL10_Yescrypt_Check!") != 0) {
        fprintf(stderr, "FAIL: YESCRYPT ($y$) verification failed\n");
        return 10;
    }
    if (verify_prefix("$6$", "AutoscriptEL9_SHA512_Check!") != 0) {
        fprintf(stderr, "FAIL: SHA-512 ($6$) verification failed\n");
        return 11;
    }
    printf("[OK] Static libxcrypt verified for EL10 ($y$ YESCRYPT) and EL9 ($6$ SHA-512).\n");
    return 0;
}
EOF

gcc -Os -static -I/opt/xcrypt/include xcrypt_selftest.c /opt/xcrypt/lib/libcrypt.a -o xcrypt_selftest
./xcrypt_selftest

# ---------------------------------------------------------------------------
# 2. Download & Cryptographically Verify Dropbear 2019.78
# ---------------------------------------------------------------------------
echo "[INFO] Downloading Dropbear ${DROPBEAR_VER}..."
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 \
  -o "dropbear-${DROPBEAR_VER}.tar.bz2" \
  "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VER}.tar.bz2" || \
curl -fsSL --proto '=https' --tlsv1.2 --retry 3 \
  -o "dropbear-${DROPBEAR_VER}.tar.bz2" \
  "https://dropbear.nl/mirror/releases/dropbear-${DROPBEAR_VER}.tar.bz2"

echo "${DROPBEAR_SHA256}  dropbear-${DROPBEAR_VER}.tar.bz2" | sha256sum -c -
tar -xjf "dropbear-${DROPBEAR_VER}.tar.bz2"
cd "dropbear-${DROPBEAR_VER}"

# ---------------------------------------------------------------------------
# 3. Apply Compile-Time Hardening (localoptions.h + SSRF & Shadow Expiry Patch)
# ---------------------------------------------------------------------------
cat > localoptions.h <<'EOF'
#ifndef AUTOSCRIPT_DROPBEAR_LOCALOPTIONS_H
#define AUTOSCRIPT_DROPBEAR_LOCALOPTIONS_H

/* Fast cipher lookup tables for high-concurrency VPS throughput */
#define DROPBEAR_SMALL_CODE 0

/* Disable attack-surface forwarding features never needed on VPN nodes */
#define DROPBEAR_X11FWD 0
#define DROPBEAR_SVR_REMOTETCPFWD 0
#define DROPBEAR_SVR_AGENTFWD 0
#define DROPBEAR_CLI_AGENTFWD 0
#define DROPBEAR_CLI_PROXYCMD 0
#define DROPBEAR_CLI_NETCAT 0
#define DROPBEAR_SFTPSERVER 0

/* Keep direct-tcpip enabled for SSH tunneling, strictly guarded by SSRF filter */
#define DROPBEAR_SVR_LOCALTCPFWD 1

/* Disable legacy weak algorithms (1024-bit DSA, 3DES, CBC, SHA1-96) */
#define DROPBEAR_DSS 0
#define DROPBEAR_3DES 0
#define DROPBEAR_ENABLE_CBC_MODE 0
#define DROPBEAR_SHA1_96_HMAC 0
#define DROPBEAR_DH_GROUP1 0

/* Modern fast ciphers & KEX */
#define DROPBEAR_AES128 1
#define DROPBEAR_AES256 1
#define DROPBEAR_ENABLE_CTR_MODE 1
#define DROPBEAR_SHA2_256_HMAC 1
#define DROPBEAR_RSA 1
#define DROPBEAR_ECDSA 1
#define DROPBEAR_CURVE25519 1
#define DROPBEAR_ECDH 1
#define DROPBEAR_DH_GROUP14_SHA256 1

/* Zero DNS reverse lookup stalls & high-concurrency pre-auth burst capacity */
#define DO_HOST_LOOKUP 0
#define DO_MOTD 0
#define MAX_UNAUTH_PER_IP 15
#define MAX_UNAUTH_CLIENTS 128
#define MAX_AUTH_TRIES 5
#define AUTH_TIMEOUT 60
#define DEFAULT_KEEPALIVE 60
#define DEFAULT_IDLE_TIMEOUT 300
#define DEFAULT_RECV_WINDOW 65536

#endif
EOF

python3 - <<'PY'
import pathlib, sys

# 1) Patch common-session.c: enforce /etc/shadow sp_expire in real time
cs_path = pathlib.Path("common-session.c")
cs_src = cs_path.read_text()
old_shadow = """\t\tstruct spwd *spasswd = getspnam(ses.authstate.pw_name);
\t\tif (spasswd && spasswd->sp_pwdp) {
\t\t\tpasswd_crypt = spasswd->sp_pwdp;
\t\t}"""
new_shadow = """\t\tstruct spwd *spasswd = getspnam(ses.authstate.pw_name);
\t\tif (spasswd) {
\t\t\tlong today_days = (long)(time(NULL) / 86400);
\t\t\tif (spasswd->sp_expire >= 0 && today_days > spasswd->sp_expire) {
\t\t\t\tdropbear_log(LOG_WARNING, "Expired shadow account '%s' rejected", ses.authstate.pw_name);
\t\t\t\tpasswd_crypt = "!!";
\t\t\t} else if (spasswd->sp_pwdp) {
\t\t\t\tpasswd_crypt = spasswd->sp_pwdp;
\t\t\t}
\t\t}"""
if old_shadow not in cs_src:
    sys.exit("ERROR: shadow anchor not found in common-session.c")
cs_path.write_text(cs_src.replace(old_shadow, new_shadow, 1))

# 2) Patch netio.c: DNS-rebinding-proof binary sockaddr SSRF & internal daemon isolation
netio_path = pathlib.Path("netio.c")
netio_src = netio_path.read_text()

helper_fn = """#include <arpa/inet.h>
#include <netinet/in.h>

static int autoscript_is_udpgw_port(const char *remoteport) {
\tint port = remoteport ? atoi(remoteport) : 0;
\treturn (port == 7100 || port == 7200 || port == 7300);
}

static int autoscript_ipv4_allowed(uint32_t ip_host_order, int allow_udpgw_loopback) {
\tuint8_t b0 = (uint8_t)((ip_host_order >> 24) & 0xFF);
\tuint8_t b1 = (uint8_t)((ip_host_order >> 16) & 0xFF);
\t/* Loopback 127.0.0.0/8 and Unspecified 0.0.0.0/8: ONLY permit BadVPN UDPGW (7100/7200/7300) */
\tif (b0 == 127 || b0 == 0) {
\t\treturn allow_udpgw_loopback ? 1 : 0;
\t}
\t/* Block Cloud Metadata 169.254.0.0/16 (IMDS SSRF) */
\tif (b0 == 169 && b1 == 254) return 0;
\t/* Block RFC1918 & CGNAT internal VPC networks */
\tif (b0 == 10) return 0;
\tif (b0 == 172 && (b1 >= 16 && b1 <= 31)) return 0;
\tif (b0 == 192 && b1 == 168) return 0;
\tif (b0 == 100 && (b1 >= 64 && b1 <= 127)) return 0;
\t/* Block Multicast & Reserved >= 224.0.0.0/4 */
\tif (b0 >= 224) return 0;
\treturn 1;
}

static int autoscript_sockaddr_allowed(const struct addrinfo *r, const char *remoteport) {
\tint allow_udpgw = autoscript_is_udpgw_port(remoteport);
\tif (!r || !r->ai_addr) return 0;
\tif (r->ai_family == AF_INET) {
\t\tconst struct sockaddr_in *sin = (const struct sockaddr_in *)r->ai_addr;
\t\treturn autoscript_ipv4_allowed(ntohl(sin->sin_addr.s_addr), allow_udpgw);
\t}
\tif (r->ai_family == AF_INET6) {
\t\tconst struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)r->ai_addr;
\t\tconst unsigned char *b = sin6->sin6_addr.s6_addr;
\t\tif (IN6_IS_ADDR_LOOPBACK(&sin6->sin6_addr) || IN6_IS_ADDR_UNSPECIFIED(&sin6->sin6_addr)) {
\t\t\treturn allow_udpgw ? 1 : 0;
\t\t}
\t\tif (IN6_IS_ADDR_V4MAPPED(&sin6->sin6_addr)) {
\t\t\tuint32_t v4 = ((uint32_t)b[12] << 24) | ((uint32_t)b[13] << 16) | ((uint32_t)b[14] << 8) | (uint32_t)b[15];
\t\t\treturn autoscript_ipv4_allowed(v4, allow_udpgw);
\t\t}
\t\t/* Block IPv6 Link-Local fe80::/10, ULA/Cloud-IMDS fc00::/7, Multicast ff00::/8 */
\t\tif (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return 0;
\t\tif ((b[0] & 0xfe) == 0xfc) return 0;
\t\tif (b[0] == 0xff) return 0;
\t\treturn 1;
\t}
\treturn 0;
}
"""

anchor_inc = '#include "debug.h"\n'
if anchor_inc not in netio_src:
    sys.exit("ERROR: include anchor not found in netio.c")
netio_src = netio_src.replace(anchor_inc, anchor_inc + "\n" + helper_fn, 1)

old_loop = """\tfor (r = c->res_iter; r; r = r->ai_next)
\t{
\t\tdropbear_assert(c->sock == -1);"""
new_loop = """\tfor (r = c->res_iter; r; r = r->ai_next)
\t{
\t\tdropbear_assert(c->sock == -1);
\t\tif (!autoscript_sockaddr_allowed(r, c->remoteport)) {
\t\t\tm_free(c->errstring);
\t\t\tc->errstring = m_strdup("Target address prohibited by security policy");
\t\t\tcontinue;
\t\t}"""
if old_loop not in netio_src:
    sys.exit("ERROR: connect_try_next loop anchor not found in netio.c")
netio_path.write_text(netio_src.replace(old_loop, new_loop, 1))

# 3) Patch svr-tcpfwd.c: fast-path port=0 & internal control port guard
fwd_path = pathlib.Path("svr-tcpfwd.c")
fwd_src = fwd_path.read_text()
old_fwd = """\t/* best be sure */
\tif (origport > 65535 || destport > 65535) {
\t\tTRACE(("leave newtcpdirect: port > 65535"))
\t\tgoto out;
\t}"""
new_fwd = """\t/* best be sure */
\tif (destport == 0 || origport > 65535 || destport > 65535) {
\t\tTRACE(("leave newtcpdirect: invalid port"))
\t\tgoto out;
\t}
\tif ((strcasecmp(desthost, "localhost") == 0 || strncmp(desthost, "127.", 4) == 0 ||
\t     strncmp(desthost, "0.", 2) == 0 || strcmp(desthost, "::1") == 0 || strcmp(desthost, "[::1]") == 0) &&
\t    !(destport == 7100 || destport == 7200 || destport == 7300)) {
\t\tdropbear_log(LOG_WARNING, "Blocked loopback direct-tcpip to %s:%u", desthost, destport);
\t\tgoto out;
\t}"""
if old_fwd not in fwd_src:
    sys.exit("ERROR: newtcpdirect anchor not found in svr-tcpfwd.c")
fwd_path.write_text(fwd_src.replace(old_fwd, new_fwd, 1))
print("[OK] Hardened Dropbear 2019.78 security patches applied cleanly.")
PY

# ---------------------------------------------------------------------------
# 4. Configure & Compile Static Hardened Binary (dropbear + dropbearkey ONLY)
# ---------------------------------------------------------------------------
export CPPFLAGS="-I/opt/xcrypt/include"
export CFLAGS="-Os -fcommon -fstack-protector-strong -ffunction-sections -fdata-sections"
export LDFLAGS="-L/opt/xcrypt/lib -static -Wl,--gc-sections"
export LIBS="/opt/xcrypt/lib/libcrypt.a -lz"

./configure \
  --prefix=/usr \
  --sysconfdir=/etc/dropbear \
  --enable-static \
  --enable-bundled-libtom \
  --disable-pam \
  --disable-lastlog \
  --disable-utmp \
  --disable-utmpx \
  --disable-wtmp \
  --disable-wtmpx \
  --disable-pututline \
  --disable-pututxline

make -j"$JOBS" PROGRAMS="dropbear dropbearkey" STATIC=1
strip --strip-unneeded dropbear dropbearkey

# Verify static linkage & exact 2019.78 banner
file dropbear | tee /dev/stderr | grep -qi "statically linked"
VER_OUT="$(./dropbear -V 2>&1 || true)"
echo "[INFO] Built binary version output: ${VER_OUT}"
echo "$VER_OUT" | grep -q "2019.78"

# ---------------------------------------------------------------------------
# 5. Package Prebuilt Archive + SHA-256 Manifest
# ---------------------------------------------------------------------------
STAGE_DIR="${WORK_DIR}/package"
mkdir -p "$STAGE_DIR"
install -m 0755 dropbear "${STAGE_DIR}/dropbear"
install -m 0755 dropbearkey "${STAGE_DIR}/dropbearkey"

cat > "${STAGE_DIR}/BUILD_INFO.txt" <<EOF
Component   : Dropbear SSH Server (Autoscript Hardened Edition)
Version     : ${DROPBEAR_VER}
Target Arch : ${ARCH_LABEL}
Linkage     : 100% Static (musl + libxcrypt ${LIBXCRYPT_VER} + zlib)
Password    : YESCRYPT (\$y$, EL10), SHA-512 (\$6$, EL9), SHA-256 (\$5$), bcrypt
Security    : SSRF/IMDS/RFC1918/Loopback isolation (UDPGW 7100-7300 allowed),
              Shadow sp_expire real-time enforcement, RemoteTcpFwd disabled,
              DSA/3DES/CBC disabled, Reverse-DNS stall disabled.
Built At    : $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

(
  cd "$STAGE_DIR"
  sha256sum dropbear dropbearkey > SHA256SUMS
  ARCHIVE_NAME="dropbear-${DROPBEAR_VER}-${ARCH_LABEL}.tar.gz"
  tar -czf "${OUT_DIR}/${ARCHIVE_NAME}" dropbear dropbearkey SHA256SUMS BUILD_INFO.txt
)

(
  cd "$OUT_DIR"
  ARCHIVE_NAME="dropbear-${DROPBEAR_VER}-${ARCH_LABEL}.tar.gz"
  sha256sum "$ARCHIVE_NAME" | tee "dropbear-${DROPBEAR_VER}-${ARCH_LABEL}.sha256"
  ls -lh "$ARCHIVE_NAME" "dropbear-${DROPBEAR_VER}-${ARCH_LABEL}.sha256"
)

echo "[OK] Hardened prebuilt Dropbear ${DROPBEAR_VER} (${ARCH_LABEL}) ready in ${OUT_DIR}."
