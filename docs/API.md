# Autoscript VPN — API Reference Manual

> **Version:** 5.3.0 (Production Release)  
> **Server Engine:** High-performance Go RESTful Daemon (`api-server`) powered by FastHTTP & SQLite (Zero CGO)  
> **Repository:** [https://github.com/risqinf/autoscript](https://github.com/risqinf/autoscript)

---

## 1. Overview & Architecture

Autoscript provides a unified, production-grade RESTful API server for automated account lifecycle management, real-time login monitoring, network quota tracking, and system health telemetry.

```
                  ┌──────────────────────────────────────────────┐
                  │              Client / Frontend               │
                  └──────────────────────┬───────────────────────┘
                                         │ HTTPS / Bearer Token
                                         ▼
                  ┌──────────────────────────────────────────────┐
                  │    HAProxy (Port 443) -> Nginx (Port 81)     │
                  └──────────────────────┬───────────────────────┘
                                         │ Reverse Proxy (/api)
                                         ▼
                  ┌──────────────────────────────────────────────┐
                  │         Go API Daemon (Port 9000)            │
                  │   FastHTTP Router + In-Memory Rate Limiter   │
                  └──────┬───────────────┬────────────────┬──────┘
                         │               │                │
            ┌────────────▼────┐   ┌──────▼──────┐   ┌─────▼──────────┐
            │ /etc/xray/      │   │ /var/log/   │   │ /etc/noobzvpns/│
            │ xray.db (WAL)   │   │ xray/access │   │ db_user.json   │
            │ accounts table  │   │ access.log  │   │ active_devices │
            └─────────────────┘   └─────────────┘   └────────────────┘
```

### Connection Details

| Attribute | Value |
|---|---|
| **Public Base URL** | `https://<your-domain>/api` |
| **Internal Local URL** | `http://127.0.0.1:9000/api` |
| **Authentication** | `Authorization: Bearer <API_TOKEN>` |
| **Request / Response Format** | `application/json; charset=utf-8` |
| **Rate Limit** | 100 requests per 60 seconds per client IP (configurable) |

### API Tokens

API tokens are managed on your VPS via `menu` -> `API Menu` (or using `menu-api`). Tokens are securely hashed and stored in `/etc/api/api.db`. Every request (except `/api/health`) must include the bearer header:

```http
Authorization: Bearer 8f14e45fceea167a5a36dedd4bea2543
```

---

## 2. Standard Response Envelope

All endpoints return a uniform JSON envelope ensuring predictable error handling across frontends, web dashboards, and Telegram bots.

### Success Response (`200 OK`, `201 Created`)

```json
{
  "success": true,
  "code": 200,
  "message": "Operation completed successfully",
  "data": {},
  "meta": {
    "total": 1,
    "page": 1,
    "per_page": 20
  }
}
```

### Error Response (`400`, `401`, `404`, `409`, `500`)

```json
{
  "success": false,
  "code": 400,
  "error": {
    "type": "VALIDATION_ERROR",
    "message": "Validation failed",
    "details": [
      {
        "field": "username",
        "message": "must be 3-32 alphanumeric characters or underscore"
      }
    ]
  }
}
```

### HTTP Status Code Matrix

| Status Code | Type | Meaning |
|---|---|---|
| **200 OK** | Success | Standard response for GET, PUT, DELETE, Renew, and Recovery. |
| **201 Created** | Success | New account or trial account successfully provisioned. |
| **400 Bad Request** | Client Error | Input validation failure or malformed JSON payload. |
| **401 Unauthorized** | Security | Missing, invalid, or expired Bearer token. |
| **404 Not Found** | Client Error | Target account or system resource does not exist. |
| **409 Conflict** | Client Error | Username or UUID is already registered and active. |
| **429 Too Many Requests** | Rate Limit | Request rate exceeded limit (default 100 req/min). |
| **500 Internal Error** | Server Error | Internal service failure, database exception, or binary error. |

---

## 3. Supported Protocol Matrix

The `{protocol}` path parameter accepts the following identifiers:

| Protocol Identifier | Protocol & Engine Description | Transport Matrix / Features |
|---|---|---|
| `ssh` | OpenSSH & Dropbear daemon + Go WebSocket | Dropbear (109), SSH-WS (80, 443), BadVPN (7300), SlowDNS DNSTT (53/5300 UDP) |
| `vless` | Xray-core VLESS inbound | WebSocket, HTTPUpgrade, XHTTP, gRPC, TLS |
| `vmess` | Xray-core VMESS inbound | WebSocket, HTTPUpgrade, XHTTP, gRPC, TLS |
| `trojan` | Xray-core Trojan inbound | WebSocket, HTTPUpgrade, XHTTP, gRPC, TLS |
| `noobz` | NoobzVPN core daemon | TCP (8585), WebSocket (`/noobz`), authentic device-id tracking |

---

## 4. Accounts Management API

### 4.1. Create Account
`POST /api/accounts/{protocol}`

Provisions a new account across the SQLite database, daemon configuration, and OS userland.

#### Request Parameters

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `username` | string | **Yes** | — | 3-32 alphanumeric characters or underscore (`^[a-zA-Z0-9_]{3,32}$`). |
| `password` | string | Optional | Auto-gen | Required for `ssh` & `noobz`. Prohibited characters: spaces, tabs, colons, newlines. |
| `secret` | string | Optional | Auto UUIDv4 | Password/UUID for Xray protocols (`vless`, `vmess`, `trojan`). |
| `days` | integer | **Yes** | — | Account validity period (1 to 3650 days). |
| `limit_ip` | integer | Optional | `0` | Max simultaneous connections/devices (0 = unlimited). Enforced natively for Noobz. |
| `quota` | integer | Optional | `0` | Total traffic limit in Gigabytes (0 = unlimited). Supported across all protocols. |

#### Example: Create NoobzVPN Account
```bash
curl -s -X POST https://example.com/api/accounts/noobz \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "vip_noobz",
    "password": "Password123!",
    "days": 30,
    "limit_ip": 2,
    "quota": 50
  }'
```

#### Example Response (`201 Created`)
```json
{
  "success": true,
  "code": 201,
  "message": "Account created successfully",
  "data": {
    "id": 42,
    "protocol": "noobz",
    "username": "vip_noobz",
    "secret": "Password123!",
    "quota_bytes": 53687091200,
    "used_bytes": 0,
    "limit_ip": 2,
    "expired_at": "2026-10-10T12:00:00Z",
    "status": "active",
    "created_at": "2026-09-10T12:00:00Z",
    "updated_at": "2026-09-10T12:00:00Z"
  }
}
```

---

### 4.2. List Accounts
`GET /api/accounts/{protocol}?page=1&per_page=20`

Retrieves a paginated list of accounts for the specified protocol.

#### Query Parameters
- `page` (integer, default: `1`): Page number.
- `per_page` (integer, default: `20`, max: `100`): Records per page.

#### Example Request
```bash
curl -s -X GET "https://example.com/api/accounts/vless?page=1&per_page=10" \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

#### Example Response (`200 OK`)
```json
{
  "success": true,
  "code": 200,
  "message": "Accounts retrieved successfully",
  "data": [
    {
      "id": 15,
      "protocol": "vless",
      "username": "user01",
      "secret": "9a38f7e2-41f2-4e92-bc21-0a6125439401",
      "quota_bytes": 107374182400,
      "used_bytes": 1428582010,
      "limit_ip": 2,
      "expired_at": "2026-10-01T00:00:00Z",
      "status": "active",
      "created_at": "2026-09-01T00:00:00Z",
      "updated_at": "2026-09-01T00:00:00Z"
    }
  ],
  "meta": {
    "total": 1,
    "page": 1,
    "per_page": 10
  }
}
```

---

### 4.3. Get Single Account
`GET /api/accounts/{protocol}/{username}`

Retrieves details for a specific account including **real-time live byte consumption** (calculated dynamically from `ssh-ws` API for SSH, `Xray stats API` for Xray, and `db_user.json` for NoobzVPN).

```bash
curl -s -X GET https://example.com/api/accounts/noobz/vip_noobz \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

---

### 4.4. Update Account
`PUT /api/accounts/{protocol}/{username}`

Modifies quota, device limits, or adds additional days to an active account.

#### Request Body
```json
{
  "quota": 100,
  "limit_ip": 3,
  "days": 15
}
```

---

### 4.5. Renew Account
`POST /api/accounts/{protocol}/{username}/renew`

Extends the account expiration date. If the account is currently active, days are appended to the current expiry timestamp. If the account was already expired, days are counted from `now`.

#### Request Body
```json
{
  "days": 30
}
```

#### Example Response (`200 OK`)
```json
{
  "success": true,
  "code": 200,
  "message": "Account renewed successfully",
  "data": {
    "username": "vip_noobz",
    "protocol": "noobz",
    "days_added": 30,
    "new_expiry": "2026-11-09T12:00:00Z"
  }
}
```

---

### 4.6. Delete Account
`DELETE /api/accounts/{protocol}/{username}`

Performs an atomic soft-delete in SQLite (`status='deleted'`) and immediately purges the user from the live daemon routing config (Xray config, system userdel, or `noobzvpns user delete`). Soft-deleted accounts remain recoverable.

```bash
curl -s -X DELETE https://example.com/api/accounts/ssh/john_doe \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

---

### 4.7. Recover Account
`POST /api/accounts/{protocol}/{username}/recovery`

Restores a soft-deleted, expired, or suspended account back into active service, re-injects credentials into the daemon routing table, and marks status as `active`.

#### Protocol-Specific Recovery Actions:
- **`ssh`**: Recreates the Linux system user (`useradd -M -s /bin/false`), resets the user password (`chpasswd`), sets account expiry (`chage -E`), restarts/reloads Dropbear, and updates the SQLite status to `active`.
- **`noobz`**: Unblocks the account in `noobzvpns` via `noobzvpns unblock <user>` (or re-provisions with original credentials if absent) and updates SQLite status to `active`.
- **`vless` / `vmess` / `trojan`**: Re-injects user UUID/password into running Xray inbound configurations and sets SQLite status to `active`.

#### Example: Recover SSH Account
```bash
curl -s -X POST https://example.com/api/accounts/ssh/john_doe/recovery \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

#### Example: Recover NoobzVPN Account
```bash
curl -s -X POST https://example.com/api/accounts/noobz/vip_noobz/recovery \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

#### Example Response (`200 OK`)
```json
{
  "success": true,
  "code": 200,
  "message": "Account recovered successfully",
  "data": {
    "username": "vip_noobz",
    "protocol": "noobz",
    "status": "active",
    "expired_at": "2026-10-10T12:00:00Z"
  }
}
```

---

## 5. Trial Accounts API

### 5.1. Create Trial
`POST /api/trials/{protocol}`

Generates temporary trial credentials with automatic random username and password generation.

#### Request Body

| Field | Type | Required | Default | Description |
|---|---|---|---|---|
| `duration` | string | Optional | `"60m"` | Format: `30m`, `2h`, `1d`, etc. |
| `limit_ip` | integer | Optional | `1` | Simultaneous connection/device limit. |

#### Example Request
```bash
curl -s -X POST https://example.com/api/trials/noobz \
  -H "Authorization: Bearer YOUR_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "duration": "120m",
    "limit_ip": 1
  }'
```

#### Example Response (`201 Created`)
```json
{
  "success": true,
  "code": 201,
  "message": "Trial account created successfully",
  "data": {
    "account": {
      "protocol": "noobz",
      "username": "trial_9ab12c",
      "secret": "kX7qL2mP9a",
      "quota_bytes": 10737418240,
      "limit_ip": 1,
      "expired_at": "2026-09-10T14:00:00Z",
      "status": "active"
    },
    "config": {
      "protocol": "noobz",
      "username": "trial_9ab12c",
      "link": "example.com:8585@trial_9ab12c:kX7qL2mP9a",
      "remark": "NoobzVPN Payload & Identifier",
      "transports": {
        "identifier": "risqinf",
        "payload": "GET /noobz HTTP/1.1[crlf]Host: example.com[crlf]Upgrade: websocket[crlf][crlf]",
        "tcp_port": "8585",
        "ws_port": "80, 8080 (HTTP), 443 (HTTPS)"
      }
    }
  }
}
```

---

## 6. Configuration & Client Links API

### 6.1. Get Config Links & Payloads
`GET /api/config/{protocol}/{username}?domain=example.com`

Returns the complete client connection matrix for the target account.

#### Protocol-Specific Payloads Returned:

#### A. VLESS / VMESS / Trojan Matrix
Returns comprehensive transport links:
- `ws_tls`: WebSocket TLS (`:443`, path: `/{protocol}`)
- `ws_ntls`: WebSocket Non-TLS (`:80`, path: `/{protocol}`)
- `hu_tls`: HTTPUpgrade TLS (`:443`, path: `/{protocol}-hu`)
- `hu_ntls`: HTTPUpgrade Non-TLS (`:80`, path: `/{protocol}-hu`)
- `xhttp_tls`: XHTTP TLS (`:443`, path: `/{protocol}-xhttp`)
- `xhttp_ntls`: XHTTP Non-TLS (`:80`, path: `/{protocol}-xhttp`)
- `grpc_tls`: gRPC TLS (`:443`, serviceName: `{protocol}-grpc`)

#### B. SSH Matrix
- `payload_tls`: `GET / HTTP/1.1[crlf]Host: <domain>[crlf]Upgrade: websocket[crlf][crlf]`
- `payload_http`: `GET / HTTP/1.1[crlf]Host: <domain>[crlf]Upgrade: websocket[crlf][crlf]`
- `slowdns_nameserver`: Configured SlowDNS NS domain (if active).
- `slowdns_public_key`: Server curve25519 public key.
- `slowdns_port`: `53, 5300 UDP`.

#### C. NoobzVPN Matrix
- `identifier`: `"risqinf"`
- `payload`: `GET /noobz HTTP/1.1[crlf]Host: <domain>[crlf]Upgrade: websocket[crlf][crlf]`
- `tcp_port`: `8585`
- `ws_port`: `80, 8080 (HTTP), 443 (HTTPS)`

---

### 6.2. Download OpenVPN TCP Profile
`GET /api/config/openvpn/{username}`

Returns the ready-to-import `.ovpn` configuration file as an attachment (`Content-Disposition: attachment; filename="{username}.ovpn"`).

---

## 7. Monitoring & System Telemetry API

### 7.1. Login Monitor (Real-time Active Sessions)
`GET /api/monitor/{protocol}`

Inspects the live connection pool and returns active sessions, client IP addresses, authentic device hashes, and live bandwidth usage.

#### Example Request
```bash
curl -s -X GET https://example.com/api/monitor/noobz \
  -H "Authorization: Bearer YOUR_API_TOKEN"
```

#### Example Response (`200 OK`)
```json
{
  "success": true,
  "code": 200,
  "message": "Login monitor retrieved successfully",
  "data": [
    {
      "username": "farell",
      "ip_count": 1,
      "ip_limit": 1,
      "devices": [
        "0ad31b6f30b5c40df5be0b471685665e7386a4f6499ffe6e230fe2226f22808c"
      ],
      "used_bytes": 707204183,
      "quota_bytes": 0,
      "expired_at": "2026-10-07T21:49:17Z"
    }
  ]
}
```

> [!NOTE]
> For NoobzVPN, `devices` contains the genuine hardware SHA-256 device hashes registered when client applications open a tunnel session. Data is parsed directly from `/etc/noobzvpns/db_user.json`.

---

### 7.2. SlowDNS (DNSTT) Telemetry
`GET /api/system/slowdns`

Returns the runtime health, nameserver configuration, and public key of the SlowDNS daemon.

#### Example Response (`200 OK`)
```json
{
  "success": true,
  "code": 200,
  "message": "SlowDNS status retrieved successfully",
  "data": {
    "status": "active",
    "nameserver": "ns.example.com",
    "public_key": "6d123e4...b7890a",
    "port": "53 / 5300 UDP",
    "target": "127.0.0.1:109 (Dropbear)"
  }
}
```

---

### 7.3. Service Health Status
`GET /api/system/services`

Returns systemd runtime state (`active` / `inactive`) and bound ports for all system daemons:
- `haproxy` (80, 443)
- `nginx` (81)
- `xray` (1, 2, 3)
- `dropbear` (109)
- `ssh-ws` (8888)
- `sshd` (22, 3303)
- `squid` (3128)
- `openvpn-server@server-tcp-1194` (1194)
- `slowdns` (53, 5300)
- `noobzvpns` (8585)
- `vnstat`, `rsyslog`, `firewalld`

---

### 7.4. System Resource Metrics
`GET /api/system/info`

Returns host telemetry:
```json
{
  "success": true,
  "code": 200,
  "message": "System info retrieved successfully",
  "data": {
    "domain": "example.com",
    "ip": "203.0.113.10",
    "cpu": "AMD EPYC 7763 64-Core Processor",
    "cores": 2,
    "ram_total": "1984 MB",
    "ram_used": "452 MB",
    "swap_total": "2048 MB",
    "swap_used": "0 MB",
    "uptime": "14 days, 3 hours",
    "os": "Rocky Linux 9.4 (Blue Onyx)"
  }
}
```

---

### 7.5. Health Check (Unauthenticated)
`GET /api/health`

Used by uptime probes, load balancers, and external health checks. Does not require an authentication header.

```json
{
  "success": true,
  "code": 200,
  "message": "Service is healthy",
  "data": {
    "status": "ok"
  }
}
```

---

## 8. Shell API Compatibility Mode (`scripts/api/`)

In addition to the high-performance Go RESTful daemon, Autoscript provides a standard pipe-based CLI API suite located in `/usr/local/sbin/api/`. These scripts accept JSON strings via standard input (`stdin`) and output JSON to standard output (`stdout`), allowing legacy shell integrations and bot engines to operate interchangeably.

### 8.1. Available Shell Handlers Matrix (25 Scripts)

| Protocol | Account Creation | Trial Generation | Account Renewal | Soft/Hard Deletion | Account Recovery |
|---|---|---|---|---|---|
| **SSH** | `add-ssh` | `trial-ssh` | `renew-ssh` | `delete-ssh` | `recovery-ssh` |
| **VLESS** | `add-vless` | `trial-vless` | `renew-vless` | `delete-vless` | `recovery-vless` |
| **VMESS** | `add-vmess` | `trial-vmess` | `renew-vmess` | `delete-vmess` | `recovery-vmess` |
| **Trojan** | `add-trojan` | `trial-trojan` | `renew-trojan` | `delete-trojan` | `recovery-trojan` |
| **NoobzVPN** | `add-noobz` | `trial-noobz` | `renew-noobz` | `delete-noobz` | `recovery-noobz` |

### 8.2. Shell API Usage Examples

#### Creating a NoobzVPN Account
```bash
echo '{"username":"noobz_user","password":"mypassword","expired":30,"limit_ip":2,"quota":20}' | /usr/local/sbin/api/add-noobz
```

#### Creating a Trial Account
```bash
echo '{"limit_ip":1,"quota":5}' | /usr/local/sbin/api/trial-noobz
```

#### Recovering an Account (SSH or NoobzVPN)
```bash
# Recover SSH account (re-creates Linux user and updates DB)
echo '{"username":"john_doe"}' | /usr/local/sbin/api/recovery-ssh

# Recover NoobzVPN account (unblocks daemon and updates DB)
echo '{"username":"noobz_user"}' | /usr/local/sbin/api/recovery-noobz
```

All shell API handlers emit standardized JSON responses with `"status": "true"|"false"`, `"code": 200|201|400|404|500`, and structured payload objects.
