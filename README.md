# Autoscript VPN

> Version: **5.5.0** (Enterprise Release) — see [CHANGELOG.md](CHANGELOG.md).

AutoScript VPN & Tunneling Management System, engineered and extremized for **Rocky Linux 9**.

Enterprise-grade multi-protocol tunneling platform supporting **SSH All-Protocol** (OpenSSH, Dropbear, Direct SSH SSL/TLS, SSH-WS, SlowDNS DNSTT, OpenVPN), **NoobzVPN**, **VLESS**, **VMESS**, and **Trojan** with full WebSocket (`ws`), HTTPUpgrade (`hu`), XHTTP (`xhttp`), and gRPC transport matrix, fronted by HAProxy + Nginx HTTP/1.1 & HTTP/2, extreme 1 vCPU / 1 GB RAM Rocky Linux kernel/ZRAM optimization, and a million-request-ready **Go RESTful API daemon** protected by **5-Layer Strict SHA-256 + Canonical HMAC-SHA256 verification**.

---

## Key Features (v5.5.0)

- **SSH All-Protocol Quota & Live Session Engine**: Tracks and enforces bandwidth quota across **OpenSSH (`22, 3303`)**, **Dropbear (`109, 143`)**, **Direct SSH SSL/TLS (`443, 8443`)**, **SSH WebSocket (`80, 8080, 8888, 443`)**, **SlowDNS (`53, 5300` UDP)**, and **OpenVPN (`1194` TCP)** via monotonic kernel TCP byte accounting (`loop-quota-ssh.service` + `ssh_proto_usage` SQLite WAL table).
- **Real-Time Accessed Apps/Domains, Protocol, ISP & GeoIP Telemetry**: Inspect live connected users with automatic classification of **65+ apps/domains** (*YouTube, Netflix, TikTok, Instagram, WhatsApp, Telegram, ChatGPT/OpenAI, Mobile Legends, Shopee*, etc.), exact transport protocol, ISP/ASN, and GeoIP city/country via 3-tier free GeoIP APIs (`ip-api.com` -> `ipwho.is` -> `freeipapi.com` with 24h caching).
- **Flash-Sale Bulk Provisioning on Standard Endpoints**: Create, renew, or delete **1 OR up to 1,000 accounts in 1 single API request** directly on the standard REST endpoints (`POST /api/accounts/{protocol}`, `PUT /api/accounts/{protocol}`, `DELETE /api/accounts/{protocol}`, `POST /api/trials/{protocol}`, plus `add-bulk` CLI) using single-pass native Go Xray JSON mutation, single Xray reload, single SQLite WAL transaction, and `X-Idempotency-Key` deduplication.
- **Million-Request Concurrency Architecture**: Atomic in-memory SHA-256 token digest cache, 256-shard lock-free/fine-grained rate limiter, 256-shard anti-replay nonce cache, `Singleflight` request coalescing + micro-TTL snapshots, separated SQLite WAL reader/writer pools, and Nginx `upstream api_backend { keepalive 256; }`.
- **5-Layer Strict SHA-256 Cryptographic API Security**: Constant-time `Bearer` SHA-256 verification + `X-Content-SHA256` payload hash + `X-Timestamp` drift window + `X-Nonce` anti-replay + `X-Signature` Double-SHA256 canonical HMAC-SHA256 + mutual `X-Server-Signature` response headers.
- **Extreme Rocky Linux 9 Optimization (`optimize-rocky`)**: Supports **hundreds of concurrent users even on 1 vCPU / 1 GB RAM** via ZRAM compressed swap, `kdump`/`crashkernel=no` RAM reclamation, TCP BBR + `fq`, bounded socket buffers, `nf_conntrack` tuning, and `GOMEMLIMIT` + `XRAY_RAY_BUFFER_SIZE=1` daemon caps.
- **Complete Firewalld & SELinux Healing (`fix-firewall`)**: Configures all public TCP/UDP ports, SELinux booleans (`httpd_can_network_connect`, `httpd_setrlimit`, `haproxy_connect_any`), `semanage port` (`81, 82, 8080, 8443, 8888, 8585, 9000, 10011..10033` in `http_port_t`), and HTTP/2 `:82` `/api/` routing so Nginx never hits `Permission denied`.
- **Zero-Backdoor & Zero-Vulnerability Hardening**: 100% TLS-verified downloads, official Go-compiled `dnstt`, locked-down localhost Squid, Xray `127.0.0.0/8` SSRF block, UID `1000-65534` localhost SSRF iptables filter, zip-slip archive protection, and process-isolated SSH session termination (`KillMode=process`).

---

## Extreme Rocky Linux 9 Auto-Tuning Profiles

| RAM Tier | Profile | ZRAM Swap | Nginx Conn/Worker | HAProxy Maxconn | API Max Concurrency | Daemon Caps |
|---|---|---|---|---|---|---|
| **≤ 1.5 GB** | `1GB-EXTREME` | 75% RAM (`zstd`/`lzo-rle`) | 8,192 | 16,384 | 65,536 | Xray `180MiB`, API `96MiB`, SSH-WS `64MiB` |
| **≤ 3 GB** | `2GB-OPTIMIZED` | 50% RAM | 16,384 | 32,768 | 262,144 | Xray `384MiB`, API `192MiB`, SSH-WS `128MiB` |
| **≤ 6 GB** | `4GB-HIGH` | 50% RAM | 65,535 | 100,000 | 262,144 | Xray `768MiB`, API `384MiB`, SSH-WS `256MiB` |
| **> 6 GB** | `8GB+-ENTERPRISE` | 2,048 MB | 131,072 | 200,000 | 1,048,576 | Uncapped / Enterprise |

---

## Port Specifications

| Service | Port / Protocol | Forwarding / Backend | Description |
|---|---|---|---|
| **OpenSSH** | `22`, `3303` / TCP | Direct | OpenSSH Direct Tunnel & Admin |
| **Dropbear** | `109`, `143` / TCP | Direct / Internal | Dropbear SSH Backend |
| **HTTP Multiplexer** | `80`, `8080`, `8880`, `2052`, `2082`, `2086`, `2095` / TCP | HAProxy → Nginx (`:81`) | HTTP WS, HTTPUpgrade, XHTTP, REST API |
| **HTTPS / TLS Multiplexer** | `443`, `8443`, `2053`, `2083`, `2087`, `2096` / TCP | HAProxy → Nginx (`:81` H1 / `:82` H2) / `:109` | Direct SSH SSL/TLS, Xray TLS/gRPC, REST API |
| **SSH WebSocket Direct** | `8888` / TCP | `ssh-ws` daemon → `:109` | GO-TUNNEL PRO WebSocket |
| **SlowDNS (DNSTT)** | `53`, `5300` / UDP | `dnstt-server` → `:109` | DNS Stealth Tunnel |
| **OpenVPN** | `1194` / TCP (`2200` UDP) | `openvpn-server` | OpenVPN Tunnel (Status v2 Quota Tracked) |
| **Squid Proxy** | `3128`, `8000` / TCP | Localhost-restricted | Hardened Non-Open HTTP Proxy |
| **NoobzVPN** | `8585` / TCP | `noobzvpns` & Nginx `/noobz` | NoobzVPN TCP & WebSocket |
| **BadVPN / UDPGW** | `7100`, `7200`, `7300` / UDP | `ssh-ws` UDPGW | Gaming & VoIP UDP Relay |

---

## Installation

### Requirements
- **OS**: Rocky Linux 9 (`x86_64` or `aarch64`)
- **Minimum Specs**: 1 vCPU / 1 GB RAM (supports hundreds of concurrent users with `1GB-EXTREME` profile)
- **Privileges**: Root (`sudo -i`)
- **DNS**: Domain / subdomain A record pointed to server IP

### 1-Line Installation Command
```bash
dnf install epel-release -y && dnf install wget curl openssl screen -y && mkdir -p /run/screen && chmod 700 /run/screen && curl -fsSL --proto '=https' --tlsv1.2 -o install.sh https://raw.githubusercontent.com/risqinf/autoscript/main/install.sh && chmod +x install.sh && screen -S autoscript ./install.sh
```

### Standalone API Server Install / Upgrade
```bash
curl -fsSL --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/risqinf/autoscript/main/install-api.sh | bash
```

---

## Management Menu & CLI Utilities

- `menu` — Open the interactive SkyNode-styled Enterprise Control Panel
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
