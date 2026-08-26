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

Replace `{protocol}` with `ssh`, `vless`, `vmess`, or `trojan`.

### Create — `POST /api/accounts/{protocol}`
```bash
curl -X POST https://<domain>/api/accounts/ssh \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "john_doe",
    "password": "Secret123",
    "days": 30,
    "limit_ip": 2
  }'
```
**Notes:** 
- For Xray (`vless`, `vmess`, `trojan`), use `quota` (in GB) instead of `password`. If `secret` is omitted, UUID/password is auto-generated.
- `days` must be an integer.

### Renew — `POST /api/accounts/{protocol}/{username}/renew`
```bash
curl -X POST https://<domain>/api/accounts/ssh/john_doe/renew \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "days": 30
  }'
```

### Delete — `DELETE /api/accounts/{protocol}/{username}`
```bash
curl -X DELETE https://<domain>/api/accounts/ssh/john_doe \
  -H "Authorization: Bearer <token>"
```
*Note: Deletes are soft (status flips to `deleted`) so accounts remain recoverable.*

### Recovery — `POST /api/accounts/{protocol}/{username}/recovery`
Restores a soft-deleted or suspended account back into the live config.
```bash
curl -X POST https://<domain>/api/accounts/vmess/vpn_user/recovery \
  -H "Authorization: Bearer <token>"
```

### Get Account — `GET /api/accounts/{protocol}/{username}`
```bash
curl -X GET https://<domain>/api/accounts/vless/vpn_user \
  -H "Authorization: Bearer <token>"
```

---

## 3. Trials API

### Create Trial — `POST /api/trials/{protocol}`
```bash
curl -X POST https://<domain>/api/trials/vmess \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "duration": "60m",
    "limit_ip": 1
  }'
```
*Trials default to quota `10 GB` (if not SSH) and auto-generate credentials.*

---

## 4. Config API

### Get Xray Link — `GET /api/config/{protocol}/{username}`
Returns the direct `vless://` / `vmess://` / `trojan://` link.

### Get OpenVPN File — `GET /api/config/openvpn/{username}`
Returns the `.ovpn` file text.

---

## 5. Monitoring & System API

- `GET /api/status` : Services status (nginx, xray, ssh, dropbear)
- `GET /api/monitor/{protocol}` : Active login monitors and bandwidth
- `GET /api/bandwidth` : System bandwidth statistics
- `GET /api/system/info` : OS, RAM, CPU usage
- `GET /api/system/services` : Background services health
