# Autoscript VPN — API Reference

> Status: the RESTful API server is being rebuilt (C++ or Rust). This document
> describes the JSON contract implemented by the command handlers in
> `/usr/local/sbin/api/`. The future HTTP server will expose these handlers
> over `https://<domain>/api/...` with Bearer-token authentication.

---

## 1. Overview

| Item | Value |
|------|-------|
| Base URL | `https://<your-domain>/api` |
| Auth | `Authorization: Bearer <token>` |
| Content-Type | `application/json` |
| Methods | `POST` (create/trial), `PUT` (renew), `DELETE` (delete), `POST` (recovery) |
| Handlers | `/usr/local/sbin/api/<action>-<protocol>` (no `.sh` extension) |

Tokens are stored one-per-line in `/etc/api/key`. Each request body is a JSON
object; each response is a JSON object with a `status`, `code`, and either
`data` (success) or `message` (error).

### Response envelope

Success:
```json
{ "status": "true", "code": 201, "message": "...", "data": { } }
```

Error:
```json
{ "status": "false", "code": 400, "message": "Reason" }
```

### Common status codes

| Code | Meaning |
|------|---------|
| 200 | OK (delete / renew / recovery) |
| 201 | Created (add / trial) |
| 400 | Invalid input (validation failed) |
| 404 | Account not found |
| 409 | Username / UUID already in use |
| 500 | Server-side failure (config or service error) |

### Field rules

| Field | Rule |
|-------|------|
| `username` | 3–32 chars, `[a-zA-Z0-9_]` only |
| `password` (SSH) | non-empty, no spaces/tabs/newlines/colons |
| `uuid` (VLESS/VMESS) | standard UUIDv4; auto-generated if omitted |
| `uuid`/`password` (Trojan) | any non-whitespace string; auto-generated if omitted |
| `quota` | integer GB, `0` = unlimited |
| `iplimit` / `limit_ip` | integer, `0` = unlimited |
| `duration` | `<n>m` / `<n>h` / `<n>d` (e.g. `30m`, `2h`, `1d`) |
| `expired` (SSH add) | integer days, 1–3650 |
| `days` (renew) | integer days, 1–3650 |

---

## 2. SSH

### Create — `POST /api/add-ssh`
```bash
curl -X POST https://<domain>/api/add-ssh \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"username":"john_doe","password":"Secret123","expired":30,"limit_ip":2}'
```
```json
{
  "status": "true",
  "code": 201,
  "message": "SSH account created successfully",
  "data": {
    "username": "john_doe",
    "password": "Secret123",
    "domain": "your-domain",
    "ip": "203.0.113.10",
    "limit_ip": 2,
    "expired": "2025-07-15 14:30:00",
    "ports": {
      "ssh": "109", "ws_http": "80, 8888", "ws_tls": "443",
      "badvpn": "7300", "openvpn_tcp": "1194"
    },
    "config": "your-domain:1-65535@john_doe:Secret123"
  }
}
```

### Trial — `POST /api/trial-ssh`
```bash
curl -X POST https://<domain>/api/trial-ssh \
  -H "Authorization: Bearer <token>" \
  -d '{"duration":"60m","limit_ip":1}'
```
Returns `201` with the same `data` shape (auto-generated `username`/`password`).

### Renew — `PUT /api/renew-ssh`
```bash
curl -X PUT https://<domain>/api/renew-ssh \
  -H "Authorization: Bearer <token>" \
  -d '{"username":"john_doe","days":30}'
```
```json
{ "status":"true","code":200,
  "data":{"username":"john_doe","protocol":"ssh","days_added":30,"new_expiry":"2025-08-14 14:30:00"} }
```

### Delete — `DELETE /api/delete-ssh`
```bash
curl -X DELETE https://<domain>/api/delete-ssh \
  -H "Authorization: Bearer <token>" \
  -d '{"username":"john_doe"}'
```
```json
{ "status":"true","code":200,
  "message":"User john_doe deleted successfully",
  "data":{"username":"john_doe","recoverable":true} }
```

---

## 3. VLESS / VMESS / Trojan

These three share the same request/response shape. Replace `<proto>` with
`vless`, `vmess`, or `trojan`. For Trojan, the secret field is `password`
(aliased as `uuid`/`key`).

### Create — `POST /api/add-<proto>`
```bash
curl -X POST https://<domain>/api/add-vless \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"username":"vpn_user","uuid":"","quota":25,"iplimit":2,"duration":"30d"}'
```
```json
{
  "status": "true",
  "code": 201,
  "message": "VLESS account created successfully",
  "data": {
    "username": "vpn_user",
    "uuid": "abcdef12-3456-7890-abcd-ef1234567890",
    "domain": "your-domain",
    "expired": "2025-08-14 14:30:00",
    "limits": { "ip": 2, "quota_gb": 25 },
    "ports": { "ws_tls": 443, "ws_http": 80 },
    "links": {
      "ws_tls": "vless://abcdef12-...@your-domain:443?path=/vless&security=tls&encryption=none&type=ws&host=your-domain&sni=your-domain#vpn_user"
    }
  }
}
```

Notes:
- VMESS responses use the same shape; `links.ws_tls` is a `vmess://` base64 URI.
- Trojan responses use `data.key` instead of `data.uuid`; `links.ws_tls` is a `trojan://` URI.
- If `uuid` is empty or omitted, the server generates one.

### Trial — `POST /api/trial-<proto>`
```bash
curl -X POST https://<domain>/api/trial-vmess \
  -H "Authorization: Bearer <token>" \
  -d '{"duration":"60m"}'
```
Returns `201`; trials default to quota `10 GB` and `2` IP.

### Renew — `PUT /api/renew-<proto>`
```bash
curl -X PUT https://<domain>/api/renew-trojan \
  -H "Authorization: Bearer <token>" \
  -d '{"username":"vpn_user","days":15}'
```
```json
{ "status":"true","code":200,
  "data":{"username":"vpn_user","protocol":"trojan","days_added":15,"new_expiry":"2025-08-29 14:30:00"} }
```

### Delete — `DELETE /api/delete-<proto>`
```bash
curl -X DELETE https://<domain>/api/delete-vless \
  -H "Authorization: Bearer <token>" \
  -d '{"username":"vpn_user"}'
```
```json
{ "status":"true","code":200,
  "message":"vless account vpn_user deleted successfully",
  "data":{"username":"vpn_user","protocol":"vless","recoverable":true} }
```

### Recovery — `POST /api/recovery-<proto>`
Restores a soft-deleted or suspended account back into the live config.
```bash
curl -X POST https://<domain>/api/recovery-vmess \
  -H "Authorization: Bearer <token>" \
  -d '{"username":"vpn_user"}'
```
```json
{ "status":"true","code":200,
  "message":"vmess account vpn_user recovered successfully",
  "data":{"username":"vpn_user","protocol":"vmess","status":"active"} }
```

---

## 4. Data model

All account state is stored in SQLite at `/etc/xray/xray.db` (the single source
of truth). The Xray `config.json` is pure JSON; clients are added/removed with
`jq`, validated with `xray -test`, and rolled back on failure.

`accounts` table (key columns):

| Column | Type | Notes |
|--------|------|-------|
| `protocol` | TEXT | `ssh` / `vless` / `vmess` / `trojan` |
| `username` | TEXT | unique per protocol |
| `secret` | TEXT | password (SSH) or uuid/password (Xray) |
| `quota_bytes` | INTEGER | `0` = unlimited |
| `used_bytes` | INTEGER | accumulated downlink |
| `limit_ip` | INTEGER | `0` = unlimited |
| `expired_at` | INTEGER | unix epoch |
| `status` | TEXT | `active` / `suspended` / `expired` / `deleted` |

Deletes are **soft** (status flips to `deleted`) so accounts remain
recoverable. Every mutation is written to the `audit_log` table.

---

## 5. Recovery & lifecycle

| Event | Effect |
|-------|--------|
| Delete | status → `deleted`, removed from config; recoverable |
| Expire (auto) | status → `expired`, removed from config; recoverable |
| IP-limit exceeded | after a grace threshold, status → `suspended` |
| Quota exceeded | status → `suspended` |
| Recovery | re-adds client to config, status → `active` |

---

## 6. Authentication (planned server behavior)

- Bearer token in the `Authorization` header, checked in constant time.
- Tokens managed via the API menu (`menu-api`) and stored in `/etc/api/key`.
- The server binds to `127.0.0.1:9000`; TLS and public exposure are handled by
  Nginx/HAProxy. Tokens are never logged.
