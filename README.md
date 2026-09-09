# Autoscript VPN

> Version: **5.0.0** (Release) — see [CHANGELOG.md](CHANGELOG.md).

AutoScript VPN & Tunneling Management System, engineered for **Rocky Linux 9**.

Enterprise-grade multi-protocol tunneling solution supporting SSH, SlowDNS (DNSTT), NoobzVPN, VLESS, VMESS, Trojan, and OpenVPN TCP with full WebSocket (WS), HTTPUpgrade (HU), XHTTP, and gRPC transport matrix, fronted by HAProxy and Nginx with dynamic auto-tuning and a unified Go RESTful API daemon.

---

## Features

- **SSH Stack**: OpenSSH + Dropbear (109) with SSH-over-WebSocket (`GO-TUNNEL PRO`) & BadVPN UDPGW (7300).
- **SlowDNS (DNSTT)**: High-security DNS Tunneling Server (<15MB RAM footprint, dropbear target) on ports `53/udp` and `5300/udp`.
- **NoobzVPN Core**: Native integration with authentic hardware device-id tracking (1 device = 1 unique hash), listening on plain HTTP `127.0.0.1:8585` with `identifier = "risqinf"`, proxied via Nginx on `/noobz`.
- **Full Xray Transport Matrix**: VLESS, VMESS, and Trojan over WebSocket (`ws`), HTTPUpgrade (`hu`), XHTTP (`xhttp`), and gRPC via Xray-core.
- **OpenVPN TCP**: Single consolidated OpenVPN TCP service (1194) with auto-generated and verified certificates for maximum connection stability.
- **HAProxy + Nginx Front**: Single-port TLS (443) and HTTP (80) multiplexing with SNI, path, and handshake-based routing.
- **Go RESTful API Daemon (`api-server`)**: High-performance FastHTTP daemon with token auth, rate limiting, and clean architecture.
- **SQLite Single Source of Truth**: `/etc/xray/xray.db` (WAL mode, foreign keys, CHECK constraints, audit logging) with soft-delete & recovery across all protocols.
- **Quota & IP / Device Limit**: Strict bandwidth quota enforcement (in GB) and concurrent connection/device limiter (SSH/VLESS/VMESS/Trojan/Noobz).
- **Live Login & Session Telemetry**: Real-time access log parser for Xray, `ssh-ws` API session polling, and authentic hardware device hash inspection directly from `/etc/noobzvpns/db_user.json`.
- **Encrypted Backup & Restore**: Multi-method backup supporting Telegram Bot (File ID), Local Encrypted Zip, and Cloud Vault API (`cloud-vault`).
- **Dynamic Auto-Tuning**: Automatically sizes Nginx worker connections, HAProxy maxconn, TCP memory buffers, file limits, and swap space based on host RAM and CPU cores.
- **SkyNode-Style Terminal UI**: Clean, adaptive ASCII interface optimized for mobile terminals (Termux/PuTTY).

---

## Auto-Tuning Engine

The installer automatically inspects hardware resources and applies optimized kernel and proxy parameters:

| RAM Tier | Nginx Conn/Worker | HAProxy Maxconn | TCP Buffers | Swap Size | Swappiness |
|---|---|---|---|---|---|
| **≤ 1 GB** | 4,096 | 8,192 | 16 MB | 2 GB | 60 |
| **≤ 2 GB** | 16,384 | 32,768 | 32 MB | 2 GB | 15 |
| **≤ 4 GB** | 65,535 | 100,000 | 64 MB | 4 GB | 15 |
| **> 4 GB** | 131,072 | 200,000 | 128 MB | 4 GB | 15 |

---

## Port Specifications

| Service | Port / Protocol | Forwarding / Backend | Description |
|---|---|---|---|
| **OpenSSH** | `22`, `3303` / TCP | Direct | VPS Remote Administration |
| **Dropbear** | `109` / TCP | Direct / Internal | Primary SSH Service |
| **HTTP Web** | `80` / TCP | HAProxy → Nginx | HTTP Web, ACME SSL, HTTPUpgrade, WebSocket |
| **HTTPS / TLS** | `443` / TCP | HAProxy → Nginx → Backends | Multi-Protocol TLS multiplexer |
| **SlowDNS (DNSTT)** | `53`, `5300` / UDP | `dnstt-server` → Dropbear (`109`) | DNS Stealth Tunneling |
| **NoobzVPN** | `8585` / TCP | `127.0.0.1:8585` & Nginx `/noobz` | NoobzVPN TCP direct & WebSocket |
| **BadVPN / UDPGW** | `7300` / UDP | `ssh-ws` daemon | UDP Forwarding (Gaming/VoIP) |
| **OpenVPN** | `1194` / TCP | `openvpn-server` | OpenVPN TCP tunnel |

### Internal Localhost Ports (`127.0.0.1`)
- Xray API: `10085`
- Nginx Local Forwarding: `81`, `82`
- SSH WebSocket Proxy: `8888`
- SSH WebSocket API: `8081`
- NoobzVPN Daemon: `8585`
- Go RESTful API Daemon: `9000`

---

## Installation

### Requirements
- **OS**: Rocky Linux 9 (x86_64 or aarch64)
- **Privileges**: Root access (`sudo -i`)
- **DNS**: Domain or subdomain pointed (A Record) to VPS IP

### 1-Line Command
```bash
dnf install epel-release -y ; dnf update -y ; dnf install wget curl openssl screen -y ; mkdir -p /run/screen ; chmod 777 /run/screen ; curl -sSL -o install.sh https://raw.githubusercontent.com/risqinf/autoscript/main/install.sh || wget -q -O install.sh https://raw.githubusercontent.com/risqinf/autoscript/main/install.sh ; chmod +x install.sh ; screen -S autoscript ./install.sh ; if [ $? -ne 0 ]; then rm -f install.sh; fi
```

*If your connection drops during installation, reconnect and run `screen -r autoscript`.*

---

## Management Menu

To open the interactive control dashboard, simply run:
```bash
menu
```

### Menu Structure
```
ENTERPRISE VPN MANAGER (v5.0.0)
├── Accounts Summary: SSH [ # ]  VLESS [ # ]  VMESS [ # ]  TROJAN [ # ]  NOOBZ [ # ]
├── Services Status : SSH+WS, SlowDNS, Xray, Nginx, HAProxy, OpenVPN, Squid, NoobzVPN, API
│
├── ACCOUNT PANELS
│   ├── 1) SSH / OpenVPN Panel    (add, trial, delete, renew, list, config, recovery, cek, slowdns)
│   ├── 2) VLESS Panel            (WS, HTTPUpgrade, XHTTP, gRPC, quota, limit-ip, recovery)
│   ├── 3) VMESS Panel            (WS, HTTPUpgrade, XHTTP, gRPC, quota, limit-ip, recovery)
│   ├── 4) TROJAN Panel           (WS, HTTPUpgrade, XHTTP, gRPC, quota, limit-ip, recovery)
│   └── 5) NoobzVPN Panel         (add, trial, delete, renew, list, config, recovery, live device-id check)
│
├── TOOLS
│   ├── 6) Auto Bulk Create       (Generate batch accounts)
│   ├── 7) Account Cleaner        (Purge expired / deleted records)
│   ├── 8) User Checker           (Realtime multi-protocol login viewer)
│   └── 9) API Menu               (Generate & manage RESTful API tokens)
│
└── SERVER
    ├── 10) System Menu           (Domain, SSL, DNS, Speedtest, BBR, Dropbear, Timers)
    ├── 11) Backup / Restore      (Telegram Bot, Manual Zip, Cloud Vault)
    └── 12) RDNS Client           (Coming soon)
```

---

## Request Routing Matrix (HAProxy + Nginx)

Single TLS port (443) and HTTP port (80) multiplexes every protocol through Nginx:

| Path / Signature | Target Service | Backend Protocol |
|---|---|---|
| `/vless` | `127.0.0.1:1` | Xray VLESS WebSocket |
| `/vless-hu` | `127.0.0.1:1` | Xray VLESS HTTPUpgrade |
| `/vless-xhttp` | `127.0.0.1:1` | Xray VLESS XHTTP |
| `vless-grpc` | `127.0.0.1:1` | Xray VLESS gRPC |
| `/vmess` | `127.0.0.1:3` | Xray VMESS WebSocket |
| `/vmess-hu` | `127.0.0.1:3` | Xray VMESS HTTPUpgrade |
| `/vmess-xhttp` | `127.0.0.1:3` | Xray VMESS XHTTP |
| `vmess-grpc` | `127.0.0.1:3` | Xray VMESS gRPC |
| `/trojan` | `127.0.0.1:2` | Xray Trojan WebSocket |
| `/trojan-hu` | `127.0.0.1:2` | Xray Trojan HTTPUpgrade |
| `/trojan-xhttp` | `127.0.0.1:2` | Xray Trojan XHTTP |
| `trojan-grpc` | `127.0.0.1:2` | Xray Trojan gRPC |
| `/noobz` | `127.0.0.1:8585` | NoobzVPN WebSocket (`noobz_ws`) |
| `/ssh` | `127.0.0.1:8888` | SSH-WS Proxy (GO-TUNNEL PRO) |
| `/` with `Sec-WebSocket-Key` | `127.0.0.1:3` | VMESS Root Path multiplex |
| `/` without header | `127.0.0.1:8888` | SSH WebSocket direct injector |

---

## Project Structure

```
autoscript/
├── install.sh              # Unified installer for Rocky Linux 9
├── uninstall.sh            # Complete uninstaller and environment purger
├── VERSION                 # Semantic version file (5.0.0)
├── LICENSE                 # Apache License 2.0
├── README.md               # Main project manual
├── docs/
│   └── API.md              # Exhaustive RESTful API reference
├── files/                  # Production Go RESTful API daemon (FastHTTP + SQLite)
│   ├── cmd/server/         # Server entrypoint and DI container
│   ├── internal/           # Config, handler, service, repository, model, validator
│   └── api-server.service  # Systemd daemon configuration
└── scripts/
    ├── lib/                # Common shell libraries (common, db, xraycfg, account)
    ├── menu/               # Interactive menu scripts (menu, menu-ssh, menu-noobz, ...)
    ├── ssh/                # SSH CLI management commands
    ├── noobz/              # NoobzVPN CLI commands (add, trial, delete, renew, list, cek, recovery)
    ├── vless/              # VLESS CLI commands
    ├── vmess/              # VMESS CLI commands
    ├── trojan/             # Trojan CLI commands
    ├── system/             # System utilities (backup, restore, slowdns, status, ...)
    └── api/                # Pipe-based shell API compatibility handlers
```

---

## RESTful API Server

Autoscript includes a native Go RESTful API daemon (`api-server`) listening on `127.0.0.1:9000` (reverse proxied by Nginx at `https://<your-domain>/api`):
- **Bearer Token Authentication**: Secure token verification via `/etc/api/api.db`.
- **Full Protocol Coverage**: `ssh`, `vless`, `vmess`, `trojan`, `noobz`.
- **Native Device & Traffic Telemetry**: Real-time traffic accounting and authentic hardware device hash tracking.

See the complete [API Documentation](docs/API.md) for full request/response schemas and code examples.

---

## Uninstallation

To completely remove Autoscript and restore server settings:
```bash
uninstall
```
This cleanly stops all systemd services, removes installed binaries, flushes firewall rules (while preserving SSH port 22), and cleans configurations and databases.

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
