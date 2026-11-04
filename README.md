# Autoscript VPN

> Version: **5.6.0** (Enterprise Release — EL9 & EL10) — see [CHANGELOG.md](CHANGELOG.md).

AutoScript VPN & Tunneling Management System, engineered and extremized for **Enterprise Linux 9 & 10** (**Rocky Linux 9–10**, **RHEL 9–10**, **AlmaLinux 9–10**, **Oracle Linux 9–10**).

Enterprise-grade multi-protocol tunneling platform supporting **SSH All-Protocol** (OpenSSH, Prebuilt Hardened Dropbear 2019.78, Direct SSH SSL/TLS, SSH-WS, Prebuilt SlowDNS DNSTT, OpenVPN), **NoobzVPN**, **VLESS**, **VMESS**, and **Trojan** with full WebSocket (`ws`), HTTPUpgrade (`hu`), XHTTP (`xhttp`), and gRPC transport matrix, fronted by HAProxy + Nginx HTTP/1.1 & HTTP/2, extreme 1 vCPU / 1 GB RAM kernel/ZRAM optimization, and a zero-downtime high-concurrency **Go RESTful API daemon** protected by **5-Layer Strict SHA-256 + Canonical HMAC-SHA256 verification**.

---

## Key Features (v5.6.0)

- **Prebuilt Hardened Binaries (Zero VPS Compile Time)**: Ships cryptographically SHA-256-verified static binaries for **`Dropbear 2019.78`** (`dropbear` + `dropbearkey` linked with static `libxcrypt` supporting both EL9 `$6$` SHA-512 and EL10 `$y$` YESCRYPT, compile-time SSRF/IMDS/loopback isolation, and real-time `/etc/shadow` `sp_expire` enforcement), **`dnstt-server`** (SlowDNS), and **`autoscript-api`** (`linux-amd64` & `linux-arm64`) — installs in ~1–2 seconds without installing GCC or Go on the VPS.
- **Multi-Distro Enterprise Linux 9 & 10 Support**: Native support across **Rocky Linux 9–10**, **RHEL 9–10**, **AlmaLinux 9–10**, and **Oracle Linux 9–10** (`x86_64` & `aarch64`), automatically configuring CRB / CodeReady Builder + EPEL 9/10 across DNF4 and DNF5.
- **Zero-Downtime Simultaneous Order Burst Engine**: Handles **100+ simultaneous buyer orders** at the exact same millisecond with zero `SQLITE_BUSY`, zero `/etc/passwd` lock failures, and zero Xray restart storms via **Leader-Follower Group-Commit Xray Write Coalescing**, **Cross-Process `flock` Batch `/etc/shadow` Mutation**, **DB-First Atomic Reservation**, and **SQLite WAL `busy_timeout(15000)`**.
- **Complete Standard REST Endpoints & Auto-Detect User Login**: Full Create (`POST /api/accounts/{protocol}`, `POST /api/accounts`), Delete (`DELETE /api/accounts/{protocol}/{username}`, `DELETE /api/users/{username}`), Renew (`POST /api/accounts/{protocol}/{username}/renew`, `POST /api/users/{username}/renew`), and **Auto-Detect User Login & All Information** (`GET /api/users/{username}/login`, `GET /api/users/{username}`) returning online state, auto-detected protocol(s), transport, IPs, ISP, GeoIP, accessed apps/domains, quota breakdown, and connection `config` links.

- **SSH All-Protocol Quota & Live Session Engine**: Tracks and enforces bandwidth quota across **OpenSSH (`22, 3303`)**, **Dropbear (`109, 143`)**, **Direct SSH SSL/TLS (`443, 8443`)**, **SSH WebSocket (`80, 8080, 8888, 443`)**, **SlowDNS (`53, 5300` UDP)**, and **OpenVPN (`1194` TCP)** via monotonic kernel TCP byte accounting (`loop-quota-ssh.service` + `ssh_proto_usage` SQLite WAL table).
- **Real-Time Accessed Apps/Domains, Protocol, ISP & GeoIP Telemetry**: Inspect live connected users with automatic classification of **65+ apps/domains** (*YouTube, Netflix, TikTok, Instagram, WhatsApp, Telegram, ChatGPT/OpenAI, Mobile Legends, Shopee*, etc.), exact transport protocol, ISP/ASN, and GeoIP city/country via 3-tier free GeoIP APIs (`ip-api.com` -> `ipwho.is` -> `freeipapi.com` with 24h caching).
- **Flash-Sale Bulk Provisioning on Standard Endpoints**: Create, renew, or delete **1 OR up to 1,000 accounts in 1 single API request** directly on the standard REST endpoints (`POST /api/accounts/{protocol}`, `PUT /api/accounts/{protocol}`, `DELETE /api/accounts/{protocol}`, `POST /api/trials/{protocol}`, plus `add-bulk` CLI) using single-pass native Go Xray JSON mutation, single Xray reload, single SQLite WAL transaction, and `X-Idempotency-Key` deduplication.
- **Million-Request Concurrency Architecture**: Atomic in-memory SHA-256 token digest cache, 256-shard lock-free/fine-grained rate limiter, 256-shard anti-replay nonce cache, `Singleflight` request coalescing + micro-TTL snapshots, separated SQLite WAL reader/writer pools, and Nginx `upstream api_backend { keepalive 256; }`.
- **5-Layer Strict SHA-256 Cryptographic API Security**: Constant-time `Bearer` SHA-256 verification + `X-Content-SHA256` payload hash + `X-Timestamp` drift window + `X-Nonce` anti-replay + `X-Signature` Double-SHA256 canonical HMAC-SHA256 + mutual `X-Server-Signature` response headers.
- **Extreme Rocky Linux 9 Optimization (`optimize-rocky`)**: Supports **hundreds of concurrent users even on 1 vCPU / 1 GB RAM** via ZRAM compressed swap, `kdump`/`crashkernel=no` RAM reclamation, TCP BBR + `fq`, bounded socket buffers, `nf_conntrack` tuning, and `GOMEMLIMIT` + `XRAY_RAY_BUFFER_SIZE=1` daemon caps.
- **Complete Firewalld & SELinux Healing (`fix-firewall`)**: Configures all public TCP/UDP ports, SELinux booleans (`httpd_can_network_connect`, `httpd_setrlimit`, `haproxy_connect_any`), `semanage port` (`81, 82, 8080, 8443, 8888, 8585, 9000, 10011..10033` in `http_port_t`), and HTTP/2 `:82` `/api/` routing so Nginx never hits `Permission denied`.
- **Zero-Backdoor & Zero-Vulnerability Hardening**: 100% TLS-verified downloads, official Go-compiled `dnstt`, locked-down localhost Squid, Xray `127.0.0.0/8` SSRF block, UID `1000-65534` localhost SSRF iptables filter, zip-slip archive protection, and process-isolated SSH session termination (`KillMode=process`).

---

## Extreme Enterprise Linux 9 & 10 Auto-Tuning & `ulimit` Profiles

Every systemd service (`xray`, `api-server`, `dropbear`, `sshd`, `ssh-ws`, `nginx`, `haproxy`, `squid`, `noobzvpns`, `slowdns`, `openvpn-server@`, `dnsmasq`, and all quota/IP-limit daemons) is configured with strict zero-bottleneck `ulimit` ceilings:
- **`LimitNOFILE=1048576`** (`open files -n`: 1,048,576; Squid `max_filedescriptors 65535`; Nginx `worker_rlimit_nofile >= 65535`)
- **`LimitNPROC=65535`** & **`TasksMax=infinity`** (`max user processes -u`)
- **`LimitMEMLOCK=infinity`**, **`LimitFSIZE=infinity`**, **`LimitDATA=infinity`**, **`LimitSTACK=infinity`**, **`LimitAS=infinity`**
- **`LimitCORE=0`** (`core file size -c`: `0` — prevents crash core-dump disk I/O freezes on small SSD VPS nodes)

| RAM Tier | Profile | ZRAM Swap | Nginx Conn/Worker | HAProxy Maxconn | API Max Concurrency | Daemon Memory Caps |
|---|---|---|---|---|---|---|
| **≤ 1.5 GB** | `1GB-EXTREME` | 50% RAM (`lz4`/`zstd`) | 4,096 (`rlimit 65535`) | 8,192 | 65,536 | Xray `220MiB`, API `96MiB`, SSH-WS `96MiB` |
| **≤ 2.5 GB** | `2GB-OPTIMIZED` | 50% RAM | 16,384 (`rlimit 65535`) | 32,768 | 262,144 | Xray `512MiB`, API `192MiB`, SSH-WS `192MiB` |
| **≤ 5 GB** | `4GB-HIGH` | 35% RAM | 65,535 (`rlimit 66559`) | 100,000 | 262,144 | Xray `1536MiB`, API `512MiB`, SSH-WS `384MiB` |
| **> 5 GB** | `8GB+-ENTERPRISE` | 25% RAM | 131,072 (`rlimit 132096`) | 200,000 | 1,048,576 | Xray `3072MiB`, API `1024MiB`, SSH-WS `512MiB` |

---

## Complete Protocol, Transport & Port Specifications

### 1. SSH All-Protocol, OpenVPN, NoobzVPN, Proxy & UDP Relay Matrix

| Protocol / Service | Network / Security | Public Port(s) | Path / Endpoint | Internal Routing / Backend | Quota & Live Monitor |
|---|---|---|---|---|---|
| **OpenSSH Direct** | Raw SSH (`TCP`) | `22`, `3303` / TCP | Direct SSH | `sshd.service` (`00-autoscript.conf`, `PermitTTY no`) | Tracked (`openssh`) |
| **Dropbear 2019.78 Direct** | Raw SSH (`TCP`) | `109`, `143` / TCP | Direct SSH (`SSH-2.0-dropbear_2019.78`) | `dropbear.service` (Prebuilt Hardened Static) | Tracked (`dropbear`) |
| **Direct SSH SSL/TLS** *(Stunnel Mode)* | `TLS 1.2 / 1.3` (`TCP`) | `443`, `8443` / TCP *(+ CDN TLS: `2053, 2083, 2087, 2096`)* | Raw SSH over TLS (SNI) | HAProxy `:443/:8443` TLS → `127.0.0.1:109` (Dropbear) | Tracked (`ssh_ssl`) |
| **SSH WebSocket HTTP** *(Payload / CDN)* | `WS` (`HTTP` / `none`) | `80`, `8080`, `8888` / TCP *(+ Firewall/CDN HTTP: `8880, 2052, 2082, 2086, 2095`)* | `/ssh` or `/` *(Injector Payload)* | HAProxy `:80/:8080` → Nginx `:81` → `ssh-ws` (`:8888`) → `:109` | Tracked (`ssh_ws`) |
| **SSH WebSocket TLS (WSS)** | `WSS` (`TLS 1.2 / 1.3`) | `443`, `8443` / TCP *(+ Firewall/CDN HTTPS: `2053, 2083, 2087, 2096`)* | `/ssh` or `/` *(Payload without `Sec-WebSocket-Key`)* | HAProxy `:443/:8443` TLS → Nginx `:81` → `ssh-ws` (`:8888`) → `:109` | Tracked (`ssh_ws`) |
| **SlowDNS (DNSTT)** | Noise `Curve25519` over `UDP` DNS | `53` *(NAT → `5300`)*, `5300` / UDP | NS Subdomain (`ns.<domain>`) | `dnstt-server` (`:5300/udp`) → `127.0.0.1:109` (Dropbear) | Tracked (`slowdns`) |
| **OpenVPN TCP / UDP** | `TLS` (`AES-128/256-GCM`, `SHA256`) | `1194` / TCP *(+ Firewall ready: `1194, 2200` / UDP)* | `https://<domain>/risqinf/openvpn/tcp.ovpn` | `openvpn-server@server-tcp-1194` (`10.9.0.0/24`) | Tracked (`openvpn`) |
| **NoobzVPN Direct TCP** | Custom TCP Framing | `8585` / TCP | `<domain>:8585@user:pass` | `noobzvpns.service` (`:8585`) | Tracked (`noobz`) |
| **NoobzVPN WebSocket (HTTP & TLS)** | `WS` / `WSS` (`HTTP/1.1` & `H2`) | HTTP: `80, 8080` · TLS: `443, 8443` / TCP | `/noobz` or `/noobz-ws` | HAProxy → Nginx (`:81` / `:82`) → `127.0.0.1:8585` | Tracked (`noobz`) |
| **Squid HTTP Proxy** | `HTTP CONNECT` | `3128` *(+ Firewall `8000`)* / TCP | Proxy to VPS IP/Domain only | `squid.service` (`max_filedescriptors 65535`, anti-open-proxy ACL) | Via target SSH daemon |
| **BadVPN UDPGW** | UDP-over-SSH `direct-tcpip` | `7100`, `7200`, `7300` / UDP & Loopback TCP | `127.0.0.1:7300` (inside SSH tunnel) | Built-in `ssh-ws` UDPGW relay (allowed through Dropbear SSRF filter) | Included in SSH session |

### 2. Xray-Core (`v25.10.15`) Multi-Transport Matrix (VLESS, VMESS & Trojan)

All Xray protocols share unified TLS termination on `:443` / `:8443` (ALPN `h2, http/1.1`) and plain HTTP `:80` / `:8080` via HAProxy + Nginx, with BitTorrent & RFC1918/Loopback SSRF outbound blocking enabled by default:

| Protocol | Transport (`network`) | Security | Public Port(s) | Path / `serviceName` | Xray Inbound Tag & Loopback Port |
|---|---|---|---|---|---|
| **VLESS** | `ws` (WebSocket) | `tls` & `none` | TLS: `443, 8443` *(CDN: `2053, 2083, 2087, 2096`)* · HTTP: `80, 8080` *(CDN: `8880, 2052, 2082, 2086, 2095`)* | Path: `/vless` | `vless-ws` (`127.0.0.1:1`) |
| **VLESS** | `httpupgrade` | `tls` (H1/H2) & `none` | TLS: `443, 8443` · HTTP: `80, 8080` | Path: `/vless-hu` | `vless-hu` (`127.0.0.1:10011`) |
| **VLESS** | `xhttp` (SplitHTTP `auto`) | `tls` (H1/H2) & `none` | TLS: `443, 8443` · HTTP: `80, 8080` | Path: `/vless-xhttp` | `vless-xhttp` (`127.0.0.1:10021`) |
| **VLESS** | `grpc` (HTTP/2 Gun) | `tls` (ALPN `h2`) | TLS: `443, 8443` | `serviceName`: `vless-grpc` | `vless-grpc` (`127.0.0.1:10031`) |
| **VMESS** | `ws` (WebSocket Multipath) | `tls` & `none` | TLS: `443, 8443` *(CDN: `2053..2096`)* · HTTP: `80, 8080` *(CDN: `8880, 2052..2095`)* | Path: `/` or `/vmess` *(any path with `Sec-WebSocket-Key`)* | `vmess-ws` (`127.0.0.1:3`) |
| **VMESS** | `httpupgrade` | `tls` (H1/H2) & `none` | TLS: `443, 8443` · HTTP: `80, 8080` | Path: `/vmess-hu` | `vmess-hu` (`127.0.0.1:10013`) |
| **VMESS** | `xhttp` (SplitHTTP `auto`) | `tls` (H1/H2) & `none` | TLS: `443, 8443` · HTTP: `80, 8080` | Path: `/vmess-xhttp` | `vmess-xhttp` (`127.0.0.1:10023`) |
| **VMESS** | `grpc` (HTTP/2 Gun) | `tls` (ALPN `h2`) | TLS: `443, 8443` | `serviceName`: `vmess-grpc` | `vmess-grpc` (`127.0.0.1:10033`) |
| **Trojan** | `ws` (WebSocket) | `tls` & `none` | TLS: `443, 8443` *(CDN: `2053..2096`)* · HTTP: `80, 8080` | Path: `/trojan` | `trojan-ws` (`127.0.0.1:2`) |
| **Trojan** | `httpupgrade` | `tls` (H1/H2) & `none` | TLS: `443, 8443` · HTTP: `80, 8080` | Path: `/trojan-hu` | `trojan-hu` (`127.0.0.1:10012`) |
| **Trojan** | `xhttp` (SplitHTTP `auto`) | `tls` (H1/H2) & `none` | TLS: `443, 8443` · HTTP: `80, 8080` | Path: `/trojan-xhttp` | `trojan-xhttp` (`127.0.0.1:10022`) |
| **Trojan** | `grpc` (HTTP/2 Gun) | `tls` (ALPN `h2`) | TLS: `443, 8443` | `serviceName`: `trojan-grpc` | `trojan-grpc` (`127.0.0.1:10032`) |

### 3. Enterprise REST API & Internal Control Plane (`127.0.0.1` Isolated)

| Component | Bind / Public Access | Purpose & Security Isolation |
|---|---|---|
| **Enterprise REST API (Public)** | `https://<domain>/api/*` (`:443, :8443` H1/H2 & `:80, :8080`) | Reverse-proxied via HAProxy → Nginx (`upstream api_backend` keepalive 256, `proxy_next_upstream off`) |
| **`autoscript-api` Daemon** | `127.0.0.1:9000` | Protected by 5-Layer SHA-256 + HMAC-SHA256, firewall-closed externally, blocked from tunnel UIDs & Dropbear SSRF |
| **Nginx Reverse Proxy** | `127.0.0.1:81` (HTTP/1.1) & `127.0.0.1:82` (HTTP/2) | `proxy_protocol` listeners fed exclusively by local HAProxy |
| **Xray StatsService gRPC** | `127.0.0.1:10085` | Per-user uplink/downlink byte counters (`dokodemo-door` `api` tag) |
| **SSH-WS Metrics API** | `127.0.0.1:8081` | Local session & UDPGW telemetry for `ssh-ws` |
| **DNS Sniffer Cache (`dnsmasq`)** | `127.0.0.1:5353` | Real-time IP-to-domain correlation for connected user app detection |

---

## Installation

### Supported Operating Systems & Requirements
| Distribution | Supported Versions | Architectures |
|---|---|---|
| **Rocky Linux** | `9.x`, `10.x` | `x86_64` (`amd64`), `aarch64` (`arm64`) |
| **Red Hat Enterprise Linux (RHEL)** | `9.x`, `10.x` | `x86_64` (`amd64`), `aarch64` (`arm64`) |
| **AlmaLinux** | `9.x`, `10.x` | `x86_64` (`amd64`), `aarch64` (`arm64`) |
| **Oracle Linux** | `9.x`, `10.x` | `x86_64` (`amd64`), `aarch64` (`arm64`) |

- **Minimum Specs**: 1 vCPU / 1 GB RAM (supports hundreds of concurrent users with `1GB-EXTREME` profile)
- **Privileges**: Root (`sudo -i`)
- **DNS**: Domain / subdomain A record pointed to server IP

### 1-Line Installation Command (EL9 & EL10)
```bash
dnf install -y wget curl openssl && curl -fsSL --proto '=https' --tlsv1.2 -o install.sh https://raw.githubusercontent.com/risqinf/autoscript/main/install.sh && chmod +x install.sh && ./install.sh
```

### Standalone API Server Install / Upgrade
```bash
curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/risqinf/autoscript/main/install-api.sh | bash
```

### 1-Line Update / Upgrade Command
```bash
curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/risqinf/autoscript/main/update.sh | bash
```

---

## Management Menu & CLI Utilities

- `menu` — Open the interactive SkyNode-styled Enterprise Control Panel
- `update` — Fast 1-click update for menus, shared libraries, presets, and background services
- `menu-api` — View or rotate API Bearer Token (`/etc/api/key`) & SHA-256 HMAC Secret (`/etc/api/secret`)
- `fix-firewall` — Auto-heal Firewalld ports, SELinux booleans/ports (`http_port_t`), and Nginx HTTP/2 `/api/` blocks
- `optimize-rocky` — Apply extreme Rocky Linux 9 kernel, ZRAM, conntrack, and daemon memory optimizations
- `cek-ssh` / `cek-vless` / `cek-vmess` / `cek-trojan` / `cek-noobz` — Real-time login monitor with **All-Protocol Quota**, **Accessed Apps/Domains**, **ISP**, and **GeoIP**

---

## RESTful API Documentation

Autoscript ships with a complete Go FastHTTP RESTful API server (`api-server`) listening on `127.0.0.1:9000` and exposed securely at `https://<your-domain>/api`.

Read the exhaustive [Enterprise API Reference Manual (`docs/API.md`)](docs/API.md) for:
- Complete **5-Layer SHA-256 + Canonical HMAC-SHA256** request signing & mutual server verification
- Ready-to-use client SDK code in **Bash, Go, Python, Node.js/TypeScript, and PHP**
- **Unified Single & Flash-Sale Bulk Creation** (`POST /api/accounts/{protocol}` — 1 to 1,000 accounts/request seamlessly)
- **SSH All-Protocol Quota** (`GET /api/quota/ssh`) & **Live App/Domain/ISP/GeoIP Telemetry** (`GET /api/monitor`)

---

## Contributors

Thank you to all contributors who help advance AutoScript VPN!

<table align="center">
  <tr>
    <td align="center" width="120px">
      <a href="https://github.com/risqinf">
        <img src="https://avatars.githubusercontent.com/u/175401284?v=4" width="80px;" alt="risqinf"/><br />
        <sub><b>risqinf</b></sub>
      </a>
    </td>
    <td align="center" width="120px">
      <a href="https://github.com/nadiavpn">
        <img src="https://avatars.githubusercontent.com/u/166901582?v=4" width="80px;" alt="nadiavpn"/><br />
        <sub><b>nadiavpn</b></sub>
      </a>
    </td>
    <td align="center" width="120px">
      <a href="https://github.com/sela-putri">
        <img src="https://avatars.githubusercontent.com/u/311260220?v=4" width="80px;" alt="sela-putri"/><br />
        <sub><b>sela-putri</b></sub>
      </a>
    </td>
    <td align="center" width="120px">
      <a href="https://github.com/FN-Rerechan02">
        <img src="https://avatars.githubusercontent.com/u/207808243?v=4" width="80px;" alt="FN-Rerechan02"/><br />
        <sub><b>FN-Rerechan02</b></sub>
      </a>
    </td>
    <td align="center" width="120px">
      <a href="https://github.com/farelvpn">
        <img src="https://avatars.githubusercontent.com/u/199040492?v=4" width="80px;" alt="farelvpn"/><br />
        <sub><b>farelvpn</b></sub>
      </a>
    </td>
    <td align="center" width="120px">
      <a href="https://github.com/apps/github-actions">
        <img src="https://avatars.githubusercontent.com/in/15368?v=4" width="80px;" alt="github-actions[bot]"/><br />
        <sub><b>github-actions[bot]</b></sub>
      </a>
    </td>
  </tr>
</table>

---

## License

Licensed under the [Apache License 2.0](LICENSE).
