# Autoscript VPN

> Version: **0.2.0-beta** — see [CHANGELOG.md](CHANGELOG.md).

AutoScript VPN & Tunneling Management System, developed for **Rocky Linux 9**.

Supports SSH, VLESS, VMESS, Trojan, and OpenVPN with WebSocket (WS), TLS, and HAProxy, plus a Web API for account management.

## Features

- SSH (OpenSSH + Dropbear) with SSH-over-WebSocket (GO-TUNNEL PRO)
- VLESS, VMESS, Trojan over WebSocket (TLS + non-TLS) via Xray-core
- OpenVPN (TCP 1194) with auto-generated, verified certificates
- HAProxy + Nginx front (TLS termination, path/handshake-based WS routing)
- SQLite-backed account database with soft-delete + recovery and audit log
- Per-account quota and IP limit (VLESS/VMESS/Trojan); SSH IP limit
- Live login monitors (per-protocol IP/quota; SSH per-user bandwidth, info only)
- Encrypted backup/restore and account notifications to Telegram, configurable
  from the menu (`Telegram Setup`)
- Service-status overview and a 3-state SSH-tunnel health badge
- Strict firewall allowlist; hardened systemd services
- Adaptive, ASCII-clean UI that stays tidy on phone terminals (Termux/PuTTY)
- Auto-tuning by RAM/CPU (Nginx/HAProxy connections, TCP buffers, file limits,
  swap), so it fits a 1 CPU / 1 GB VPS and scales up on larger machines

## Auto-tuning

The installer detects total RAM and CPU count and tunes the stack to fit the
machine (no manual editing needed):

| RAM tier | Nginx conn/worker | HAProxy maxconn | TCP buffers | Swap | swappiness |
|----------|-------------------|-----------------|-------------|------|------------|
| ≤ 1 GB   | 4096   | 8192   | 16 MB  | 2 GB | 60 |
| ≤ 2 GB   | 16384  | 32768  | 32 MB  | 2 GB | 15 |
| ≤ 4 GB   | 65535  | 100000 | 64 MB  | 4 GB | 15 |
| > 4 GB   | 131072 | 200000 | 128 MB | 4 GB | 15 |

Nginx `worker_processes` follows the CPU count. Swap size is capped by free
disk (needs the swap size + 5 GB headroom). This prevents the previous
fixed `worker_connections 1048576` (which alone reserved ~445 MB/worker) from
OOM-ing a small VPS.

## Ports

| Service | Port | Notes |
|---------|------|-------|
| OpenSSH | 22, 3303 | management |
| Dropbear | 109 | SSH |
| HTTP | 80 | HAProxy → Nginx |
| HTTPS / TLS | 443 | HAProxy → Nginx → Xray/SSH-WS |
| BadVPN / UDPGW | 7300/udp | provided by ssh-ws |
| OpenVPN | 1194/tcp | |

Internal-only (bound to `127.0.0.1`, not in the firewall allowlist):
Xray API `10085`, Nginx `81`/`444`, SSH-WS proxy `8888`, SSH-WS API `8081`,
WebAPI `9000`.

## Requirements

- Rocky Linux 9 (x86_64)
- Root access
- A domain/subdomain pointed to your server IP

## Install

```shell
dnf install epel-release -y ; dnf update -y ; dnf install wget curl openssl screen -y ; wget -q https://raw.githubusercontent.com/risqinf/autoscript/main/install.sh ; chmod +x install.sh ; screen -S autoscript ./install.sh ; if [ $? -ne 0 ]; then rm -f install.sh; fi
```

## Note

If your session disconnects during installation, log back in and resume with:

```shell
screen -r autoscript
```

## Management

After installation, run the menu with:

```shell
menu
```

### Menu overview

```
Main Menu
├── Account Panels
│   ├── 1) SSH / OpenVPN     (create, trial, delete, renew, list, config,
│   │                         recovery, check login, Dropbear version)
│   ├── 2) VLESS             (create, trial, delete, renew, list, config,
│   ├── 3) VMESS              recovery, check login, set quota, set limit IP)
│   └── 4) TROJAN
├── Tools
│   ├── 5) Auto Bulk Create        7) User Checker (all protocols)
│   └── 6) Account Cleaner         8) API Menu
└── Server
    ├── 9) System Menu
    │     ├── Change Domain / Renew SSL   Dropbear version
    │     ├── Change DNS                  Change Timezone
    │     ├── Stream / Media Check        Service Status
    │     ├── Speedtest                   Telegram Setup
    │     └── Xray Core Version           Uninstall Script
    └── 10) Backup / Restore
```

Most commands are also callable directly by name, e.g. `add-ssh`, `cek-vmess`,
`status`, `set-telegram`, `backup`, `uninstall`.

### Telegram notifications

Account creation and encrypted backups are sent to the admin's Telegram. Set
the bot token and chat id from **System → Telegram Setup** (or run
`set-telegram`); it stores them at `/etc/xray/bot.key` and `/etc/xray/client.id`
and can send a test message. Telegram output uses rich HTML so a seller can
forward it straight to a buyer.

## Request routing

A single TLS port (443) and HTTP port (80) serve every protocol. HAProxy
terminates the connection and forwards to Nginx, which routes by path — and, on
the root path, by the WebSocket handshake:

| Incoming path | Routed to |
|---------------|-----------|
| `/vless` | Xray VLESS inbound (`127.0.0.1:1`) |
| `/trojan` | Xray Trojan inbound (`127.0.0.1:2`) |
| `/ssh` | SSH-WS proxy (`127.0.0.1:8888`) — recommended SSH payload path |
| `/` with `Sec-WebSocket-Key` header | Xray VMESS inbound (`127.0.0.1:3`) — multipath |
| `/` without that header | SSH-WS proxy (`127.0.0.1:8888`) |

This lets a genuine VMESS client (which always sends `Sec-WebSocket-Key`) and a
raw SSH-WS injector payload (which does not) share the same root path without
the SSH client getting a `400 Bad Request` from the VMESS inbound.

## Project Structure

```
autoscript/
├── install.sh              # Installer (Rocky Linux 9)
├── uninstall.sh            # Uninstaller
├── LICENSE                 # Apache License 2.0
├── README.md
├── docs/
│   └── API.md              # Web API documentation
├── files/                  # Reserved for the RESTful API server (WIP)
└── scripts/
    ├── lib/                # Shared libraries (common, db, xraycfg, account)
    ├── menu/               # menu, menu-ssh, menu-vless, menu-vmess, ...
    ├── ssh/                # SSH account management
    ├── vless/              # VLESS account management
    ├── vmess/              # VMESS account management
    ├── trojan/             # Trojan account management
    ├── system/             # backup, restore, db-migrate, status,
    │                       #   set-telegram, change-*, fixlog, versi-xray, ...
    └── api/                # API command handlers
```

Scripts are stored with a `.sh` extension in the repository. During
installation they are deployed to `/usr/local/sbin` as bare command names
(without `.sh`) so the menu can invoke them directly. Shared libraries are
installed to `/usr/local/sbin/lib` and API handlers to `/usr/local/sbin/api`.

## Data model

Account state lives in a single SQLite database at `/etc/xray/xray.db`
(WAL mode, foreign keys, strict CHECK constraints, audit log). The Xray
`config.json` is pure JSON with no comment markers; clients are managed with
`jq` and every change is validated with `xray -test` and rolled back on
failure. There are no `.txt` account files. Existing installs are migrated
automatically by `db-migrate` during install.

> The RESTful API server in `files/` is being rebuilt (C++ or Rust) and is
> not yet shipped.

## SSH WebSocket

SSH-over-WebSocket is provided by **GO-TUNNEL PRO**
([risqinf/websocket-proxy](https://github.com/risqinf/websocket-proxy)) — a
static Go binary installed as `/usr/local/bin/ssh-ws` with the `ssh-ws`
systemd service. On Rocky Linux 9 it is tuned to read `/var/log/secure`
(instead of Debian's `/var/log/auth.log`) and runs as root. It listens on
`127.0.0.1`-reachable port `8888` (fronted by nginx/HAProxy on 80/443),
provides UDPGW on `7300`, and a localhost monitoring API on `8081`.

## Uninstall

If the script is installed, just run the command:

```shell
uninstall
```

It stops and removes every service, binary, command, library, config, the
database, web/log directories, the SSH system users it created, and the
firewall rules it opened (keeping port 22 so you are not locked out). It also
offers to remove the swap file. `install.sh` and `uninstall.sh` delete
themselves once finished.

## API

See [docs/API.md](docs/API.md) for the full Web API documentation.

## License

Licensed under the Apache License 2.0. See the [LICENSE](LICENSE) file for details.

## Repository

https://github.com/risqinf/autoscript
