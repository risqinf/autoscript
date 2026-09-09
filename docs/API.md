# Autoscript VPN — API Reference

> **Status:** The RESTful API server runs on a dedicated high-performance Go daemon.
> This document describes the standard JSON contract implemented by the `/api` HTTP endpoints.

---

## 1. Overview

| Item | Value |
|------|-------|
| Base URL | `https://<your-domain>/api` |
| Internal | `http://127.0.0.1:9000/api` |
| Auth | `Authorization: Bearer <token>` |
| Content-Type | `application/json` |

Tokens are generated via the `menu` -> `API Menu` on your VPS and stored in `/etc/api/key`. Each request body is a JSON object; each response is a JSON object with a `success`, `code`, and either `data` (success) or `error` (failure).

### Response envelope

Success:
```json
{ 
  "success": true, 
  "code": 200, 
  "message": "Success", 
  "data": { } 
}
```

Error:
```json
{ 
  "success": false, 
  "code": 400, 
  "error": {
    "type": "VALIDATION_ERROR",
    "message": "Validation failed",
    "details": ["username is required"]
  }
}
```

### Common status codes

| Code | Meaning |
|------|---------|
| 200 | OK (GET, PUT, DELETE, Renew, Recovery) |
| 201 | Created (POST) |
| 400 | Invalid input (validation failed) |
| 401 | Unauthorized (Missing/invalid Bearer token) |
| 404 | Account not found |
| 409 | Username / UUID already in use |
| 500 | Server-side failure (config or service error) |

---

## 2. Accounts API

Replace `{protocol}` with `ssh`, `vless`, `vmess`, `trojan`, or `noobz`.

### Create — `POST /api/accounts/{protocol}`
```bash
curl -X POST https://<domain>/api/accounts/noobz \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "john_doe",
    "password": "Secret123",
    "days": 30,
    "limit_ip": 2,
    "quota": 50
  }'
```
**Notes:** 
- `quota` (in GB, 0 = unlimited) is supported for all protocols (`ssh`, `vless`, `vmess`, `trojan`, `noobz`).
- For Xray (`vless`, `vmess`, `trojan`), if `secret` is omitted, UUID/password is auto-generated.
- For `noobz`, `limit_ip` maps to device limit enforced natively by `noobzvpns`.
- `days` must be an integer.

### Renew — `POST /api/accounts/{protocol}/{username}/renew`
```bash
curl -X POST https://<domain>/api/accounts/noobz/john_doe/renew \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "days": 30
  }'
```

### Delete — `DELETE /api/accounts/{protocol}/{username}`
```bash
curl -X DELETE https://<domain>/api/accounts/noobz/john_doe \
  -H "Authorization: Bearer <token>"
```
*Note: Deletes are soft in the SQLite database while removing the client from active daemon configs/CLI, so accounts remain recoverable.*

### Recovery — `POST /api/accounts/{protocol}/{username}/recovery`
Restores a soft-deleted or suspended account back into the live config.
```bash
curl -X POST https://<domain>/api/accounts/noobz/john_doe/recovery \
  -H "Authorization: Bearer <token>"
```

### Get Account — `GET /api/accounts/{protocol}/{username}`
```bash
curl -X GET https://<domain>/api/accounts/noobz/john_doe \
  -H "Authorization: Bearer <token>"
```

---

## 3. Trials API

### Create Trial — `POST /api/trials/{protocol}`
```bash
curl -X POST https://<domain>/api/trials/noobz \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "duration": "60m",
    "limit_ip": 1
  }'
```
*Trials default to quota `10 GB` and auto-generate credentials.*

---

## 4. Config API

### Get Config Link — `GET /api/config/{protocol}/{username}`
Returns the connection config, remark, and `transports` map:
- **Xray (`vless`, `vmess`, `trojan`)**: `ws_tls`, `ws_ntls`, `hu_tls`, `hu_ntls`, `xhttp_tls`, `xhttp_ntls`, `grpc_tls`.
- **SSH**: HTTP Custom payload, plus `slowdns_nameserver`, `slowdns_public_key`, and `slowdns_port` when SlowDNS is enabled.
- **NoobzVPN (`noobz`)**: `identifier` (`risqinf`), `payload` (`GET /noobz HTTP/1.1[crlf]Host: <domain>[crlf]Upgrade: websocket[crlf][crlf]`), `tcp_port` (`8585`), and `ws_port` (`80, 8080 (HTTP), 443 (HTTPS)`).

### Get OpenVPN File — `GET /api/config/openvpn/{username}`
Returns the `.ovpn` file text.

---

## 5. Monitoring & System API

- `GET /api/status` : Services status (nginx, xray, ssh, dropbear, noobzvpns)
- `GET /api/monitor/{protocol}` : Active login monitors and bandwidth. For `noobz`, reads directly from `/etc/noobzvpns/db_user.json` with authentic `active_devices` hashes and byte statistics.
- `GET /api/bandwidth` : System bandwidth statistics
- `GET /api/system/info` : OS, RAM, CPU usage
- `GET /api/system/services` : Background services health (including `slowdns`, `noobzvpns`, `dropbear`, `xray`, `nginx`, `haproxy`)
- `GET /api/system/slowdns` : SlowDNS (DNSTT) daemon status, nameserver, public key, and forward target
