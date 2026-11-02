# Autoscript VPN — Enterprise RESTful API Reference Manual

> **Version:** 5.5.0 (Enterprise Production Release)  
> **Server Engine:** Go FastHTTP Daemon (`api-server`) + Separated SQLite WAL Reader/Writer Pools (Zero CGO)  
> **Security Standard:** 5-Layer Strict SHA-256 + Canonical HMAC-SHA256 + Mutual Response Signatures  
> **Repository:** [https://github.com/risqinf/autoscript](https://github.com/risqinf/autoscript)

---

## Table of Contents

1. [Architecture & Million-Request Engine](#1-architecture--million-request-engine)
2. [5-Layer Strict SHA-256 Cryptographic Verification](#2-5-layer-strict-sha-256-cryptographic-verification)
3. [Client Signing Examples (Bash, Go, Python, Node.js, PHP)](#3-client-signing-examples-bash-go-python-nodejs-php)
4. [Standard JSON Envelope & Error Matrix](#4-standard-json-envelope--error-matrix)
5. [Public & Auth Diagnostic Endpoints](#5-public--auth-diagnostic-endpoints)
6. [Account Lifecycle & Flash-Sale Bulk Provisioning (`POST /api/accounts/{protocol}`)](#6-account-lifecycle--flash-sale-bulk-provisioning-post-apiaccountsprotocol)
7. [Trial Account Endpoints (Single & Bulk on `POST /api/trials/{protocol}`)](#7-trial-account-endpoints-single--bulk-on-post-apitrialsprotocol)
8. [Connection Config & OpenVPN Profile Endpoints](#8-connection-config--openvpn-profile-endpoints)
9. [SSH All-Protocol Quota & Multi-Protocol Quota Endpoints](#9-ssh-all-protocol-quota--multi-protocol-quota-endpoints)
10. [Live Session Monitor, Accessed Apps/Domains, ISP & GeoIP Telemetry](#10-live-session-monitor-accessed-appsdomains-isp--geoip-telemetry)
11. [System Info, Bandwidth, Services, Rocky Optimization & Audit](#11-system-info-bandwidth-services-rocky-optimization--audit)
12. [Environment Configuration Reference](#12-environment-configuration-reference)
13. [Shell Pipe API Compatibility Matrix](#13-shell-pipe-api-compatibility-matrix)

---

## 1. Architecture & Million-Request Engine

```
                   ┌────────────────────────────────────────────────────────┐
                   │        Web Store / Telegram Bot / Billing Panel        │
                   └───────────────────────────┬────────────────────────────┘
                                               │ HTTPS (TLS 1.2/1.3, H1 & H2)
                                               │ 5-Layer SHA-256 Signed Headers
                                               ▼
                   ┌────────────────────────────────────────────────────────┐
                   │         HAProxy (:443 / :8443 / :80 / :8080)           │
                   │      ALPN Multiplexer -> Nginx :81 (H1) & :82 (H2)     │
                   └───────────────────────────┬────────────────────────────┘
                                               │ upstream api_backend (keepalive 256)
                                               ▼
                   ┌────────────────────────────────────────────────────────┐
                   │             Go FastHTTP Daemon (127.0.0.1:9000)        │
                   │  • 5-Layer SHA-256 Verifier (Atomic RAM Digest Cache)  │
                   │  • 256-Shard Lock-Free/Fine-Grained Rate Limiter       │
                   │  • 256-Shard Nonce Anti-Replay Store                   │
                   │  • Singleflight Request Coalescing + Micro-TTL Cache   │
                   │  • Async Ring-Buffered Batch Audit Logger              │
                   └──────┬────────────────────┬─────────────────────┬──────┘
                          │                    │                     │
             ┌────────────▼─────┐   ┌──────────▼──────────┐   ┌──────▼──────────────┐
             │ /etc/xray/xray.db│   │ Kernel Socket & Log │   │ Free GeoIP & App    │
             │ • Read Pool (Nx) │   │ • ss -tinpH (6 SSH) │   │ • ip-api.com/batch  │
             │ • Write Pool (1x)│   │ • OpenVPN Status v2 │   │ • ipwho.is / freeip │
             │ • ssh_proto_usage│   │ • Xray Seek-Tail    │   │ • 65+ App Classifier│
             └──────────────────┘   └─────────────────────┘   └─────────────────────┘
```

### Key Capabilities
- **Million-Request Concurrency**: Zero SQLite queries on the authentication and rate-limiting hot path. Concurrent read spikes coalesce via `Singleflight` into a single underlying collection per micro-TTL window (`1.5s–3.0s`) and return sub-microsecond RAM snapshots.
- **Flash-Sale Ready**: Provision up to **1,000 accounts in 1 single API call** with a single Xray JSON mutation, single Xray reload, single SQLite WAL transaction, and `X-Idempotency-Key` retry deduplication.
- **Both `/api/...` and `/api/v1/...` Supported**: Every endpoint is mounted under `/api/...` and `/api/v1/...` simultaneously.

---

## 2. 5-Layer Strict SHA-256 Cryptographic Verification

All endpoints except `GET /api/health` enforce **5-Layer Strict SHA-256 Verification** (`API_SECURITY_MODE=strict`). Credentials are provisioned automatically during installation and managed via `menu-api`:
- **Bearer Token**: `/etc/api/key` (also stored in `/etc/api/api.db`)
- **HMAC Secret Key**: `/etc/api/secret`

### Required Request Headers

| Layer | Header | Specification |
|---|---|---|
| **Layer 0** | *(Network Policy)* | Optional IP/CIDR allowlist via `API_ALLOWED_IPS`; `X-Real-IP` trusted exclusively from `127.0.0.1`/`::1`. |
| **Layer 1** | `Authorization` | `Bearer <API_TOKEN>` — compared in constant time via precomputed `SHA-256(token)` digests in atomic RAM. |
| **Layer 2** | `X-Content-SHA256` | Lowercase 64-char hex `SHA-256(raw_request_body)`. For empty bodies (`GET`/`DELETE`), use `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`. |
| **Layer 3** | `X-Timestamp` | Current Unix epoch seconds (e.g. `1762100000`). Must be within `±300s` (`API_MAX_SKEW_SEC`) of server time. |
| **Layer 4** | `X-Nonce` | Unique 16–128 character nonce (`[a-zA-Z0-9_-]{16,128}`). Tracked in a 256-shard anti-replay cache after signature verification. |
| **Layer 5** | `X-Signature` | Lowercase 64-char hex **Double-SHA256 + HMAC-SHA256** canonical request signature (algorithm below). |

### Layer 5 Canonical Signature Algorithm

Given `METHOD` (uppercase), `PATH` (exact URI path e.g. `/api/accounts/vless`), `CANONICAL_QUERY` (query parameters sorted lexicographically by key & value, RFC 3986 percent-encoded; empty string `""` if no query), `X_TIMESTAMP`, `X_NONCE`, `BODY_SHA256` (lowercase hex), and `TOKEN_SHA256 = hex(sha256(API_TOKEN))`:

```text
1. canonical_payload =
     METHOD + "\n" +
     PATH + "\n" +
     CANONICAL_QUERY + "\n" +
     X_TIMESTAMP + "\n" +
     X_NONCE + "\n" +
     BODY_SHA256 + "\n" +
     TOKEN_SHA256

2. canonical_hash = lowercase_hex(SHA256(canonical_payload))

3. signing_string = "ASv5.5:" + X_TIMESTAMP + ":" + canonical_hash

4. X-Signature    = lowercase_hex(HMAC_SHA256(key = UTF8(API_SECRET), msg = signing_string))
```

### Mutual Server Response Signature Headers

Every HTTP response from `api-server` is also signed by the server so clients can verify authenticity and detect MITM tampering:
- `X-Request-ID`: Unique 24-hex request ID
- `X-Response-Timestamp`: Server Unix epoch seconds
- `X-Response-SHA256`: `lowercase_hex(SHA256(raw_response_body))`
- `X-Server-Signature`: `lowercase_hex(HMAC_SHA256(API_SECRET, "ASv5.5-RESP:" + X-Response-Timestamp + ":" + X-Request-ID + ":" + X-Response-SHA256))`

---

## 3. Client Signing Examples (Bash, Go, Python, Node.js, PHP)

### Bash (`curl` + `openssl`)
```bash
#!/usr/bin/env bash
API_URL="https://vpn.yourdomain.com"
API_TOKEN="YOUR_BEARER_TOKEN"
API_SECRET="YOUR_HMAC_SECRET"

METHOD="POST"
URI_PATH="/api/accounts/vless"
QUERY=""
BODY='{"count":250,"prefix":"flash_","quota":50,"limit_ip":2,"days":30}'

TS=$(date +%s)
NONCE=$(openssl rand -hex 16)
BODY_SHA=$(printf '%s' "$BODY" | openssl dgst -sha256 | awk '{print $NF}')
TOK_SHA=$(printf '%s' "$API_TOKEN" | openssl dgst -sha256 | awk '{print $NF}')

CANON=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s' "$METHOD" "$URI_PATH" "$QUERY" "$TS" "$NONCE" "$BODY_SHA" "$TOK_SHA")
CANON_SHA=$(printf '%s' "$CANON" | openssl dgst -sha256 | awk '{print $NF}')
SIG=$(printf 'ASv5.5:%s:%s' "$TS" "$CANON_SHA" | openssl dgst -sha256 -hmac "$API_SECRET" | awk '{print $NF}')

curl -fsSL -X "$METHOD" "${API_URL}${URI_PATH}" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${API_TOKEN}" \
  -H "X-Content-SHA256: ${BODY_SHA}" \
  -H "X-Timestamp: ${TS}" \
  -H "X-Nonce: ${NONCE}" \
  -H "X-Signature: ${SIG}" \
  -H "X-Idempotency-Key: flash-order-0001" \
  -d "$BODY"
```

### Node.js / TypeScript
```ts
import crypto from "node:crypto";

export function signAutoscriptRequest(
  method: string,
  path: string,
  query: Record<string, string>,
  body: string,
  token: string,
  secret: string,
) {
  const ts = Math.floor(Date.now() / 1000).toString();
  const nonce = crypto.randomBytes(16).toString("hex");
  const bodySha = crypto.createHash("sha256").update(body).digest("hex");
  const tokenSha = crypto.createHash("sha256").update(token).digest("hex");

  const canonQuery = Object.keys(query)
    .sort()
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(query[k])}`)
    .join("&");

  const canon = [method.toUpperCase(), path, canonQuery, ts, nonce, bodySha, tokenSha].join("\n");
  const canonSha = crypto.createHash("sha256").update(canon).digest("hex");
  const sig = crypto.createHmac("sha256", secret).update(`ASv5.5:${ts}:${canonSha}`).digest("hex");

  return {
    Authorization: `Bearer ${token}`,
    "X-Content-SHA256": bodySha,
    "X-Timestamp": ts,
    "X-Nonce": nonce,
    "X-Signature": sig,
  };
}
```

### Python 3
```python
import hashlib, hmac, secrets, time, urllib.parse

def sign_autoscript_request(method: str, path: str, params: dict, body: bytes, token: str, secret: str) -> dict:
    ts = str(int(time.time()))
    nonce = secrets.token_hex(16)
    body_sha = hashlib.sha256(body).hexdigest()
    tok_sha = hashlib.sha256(token.encode()).hexdigest()

    canon_query = "&".join(
        f"{urllib.parse.quote(k, safe='')}={urllib.parse.quote(str(params[k]), safe='')}"
        for k in sorted(params.keys())
    )
    canon = "\n".join([method.upper(), path, canon_query, ts, nonce, body_sha, tok_sha])
    canon_sha = hashlib.sha256(canon.encode()).hexdigest()
    sig = hmac.new(secret.encode(), f"ASv5.5:{ts}:{canon_sha}".encode(), hashlib.sha256).hexdigest()

    return {
        "Authorization": f"Bearer {token}",
        "X-Content-SHA256": body_sha,
        "X-Timestamp": ts,
        "X-Nonce": nonce,
        "X-Signature": sig,
    }
```

### PHP 8+
```php
<?php
function signAutoscriptRequest(string $method, string $path, array $query, string $body, string $token, string $secret): array {
    $ts = (string) time();
    $nonce = bin2hex(random_bytes(16));
    $bodySha = hash('sha256', $body);
    $tokSha = hash('sha256', $token);

    ksort($query);
    $pairs = [];
    foreach ($query as $k => $v) {
        $pairs[] = rawurlencode((string)$k) . '=' . rawurlencode((string)$v);
    }
    $canonQuery = implode('&', $pairs);

    $canon = implode("\n", [strtoupper($method), $path, $canonQuery, $ts, $nonce, $bodySha, $tokSha]);
    $canonSha = hash('sha256', $canon);
    $sig = hash_hmac('sha256', "ASv5.5:{$ts}:{$canonSha}", $secret);

    return [
        "Authorization: Bearer {$token}",
        "X-Content-SHA256: {$bodySha}",
        "X-Timestamp: {$ts}",
        "X-Nonce: {$nonce}",
        "X-Signature: {$sig}",
    ];
}
```

### Go
Use `security.SignRequest(method, path, rawQuery, token, secret, ts, nonce, body)` from [`verifier.go`](../files/internal/security/verifier.go).

---

## 4. Standard JSON Envelope & Error Matrix

### Success Envelope
```json
{
  "success": true,
  "code": 200,
  "message": "Operation completed successfully",
  "data": {},
  "meta": {
    "total": 100,
    "page": 1,
    "per_page": 20
  }
}
```

### Error Codes
| HTTP Code | `error.type` | Cause |
|---|---|---|
| `400` | `VALIDATION_ERROR` | Invalid field format, reserved Linux username, or malformed JSON |
| `401` | `UNAUTHORIZED` | Missing or invalid Layer-1 Bearer token |
| `401` | `INVALID_CONTENT_HASH` | Layer-2 `X-Content-SHA256` missing or body tampered |
| `401` | `TIMESTAMP_EXPIRED` | Layer-3 `X-Timestamp` outside `±300s` clock drift window |
| `401` | `REPLAY_DETECTED` | Layer-4 `X-Nonce` missing, malformed, or already used |
| `401` | `INVALID_SIGNATURE` | Layer-5 `X-Signature` canonical HMAC-SHA256 mismatch |
| `403` | `FORBIDDEN_IP` | Client IP rejected by `API_ALLOWED_IPS` policy |
| `404` | `NOT_FOUND` | Account or endpoint does not exist |
| `409` | `CONFLICT` | Account username or Xray secret/UUID already exists |
| `429` | `RATE_LIMITED` | Per-IP rate window exceeded (inspect `X-RateLimit-Reset`) |
| `500` | `INTERNAL_ERROR` | Unexpected backend error |

---

## 5. Public & Auth Diagnostic Endpoints

### `GET /api/health` *(Public — No Auth Required)*
Returns daemon health, API version, current Unix `server_time` (for client clock synchronization), and active security mode.
```json
{
  "success": true,
  "code": 200,
  "message": "Service is healthy",
  "data": {
    "security_mode": "strict",
    "server_time": 1762100000,
    "status": "ok",
    "version": "5.5.0"
  }
}
```

### `GET /api/auth/verify` *(Protected)*
Verifies all 5 cryptographic SHA-256 layers and returns a detailed verification report.
```json
{
  "success": true,
  "code": 200,
  "message": "Multi-layer SHA-256 verification succeeded",
  "data": {
    "authenticated": true,
    "version": "5.5.0",
    "server_time": 1762100005,
    "verification": {
      "token_name": "default",
      "client_ip": "203.0.113.10",
      "security_mode": "strict",
      "verified_layers": [
        "layer0_ip_policy",
        "layer1_bearer_sha256",
        "layer2_content_sha256",
        "layer3_timestamp_window",
        "layer4_nonce_antireplay",
        "layer5_canonical_hmac_sha256"
      ],
      "body_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "token_sha256": "5994471abb01112afcc18159f6cc74b4f511b99806da59b3caf5a9c173cacfc5",
      "canonical_sha256": "9c21f0e8..."
    }
  }
}
```

---

## 6. Account Lifecycle & Flash-Sale Bulk Provisioning (`POST /api/accounts/{protocol}`)

Supported `{protocol}` values: `ssh`, `vless`, `vmess`, `trojan`, `noobz`.

All account operations use **100% standard REST endpoints** — there is NO separate non-standard endpoint for Flash Sales. `POST /api/accounts/{protocol}` natively handles **both creating 1 single account AND creating up to 1,000 accounts in 1 single request** seamlessly!

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/accounts` | Cross-protocol summary + search (`?protocol=&status=&search=&page=1&per_page=50`) |
| `POST` | `/api/accounts/{protocol}` | **Unified Create**: creates **1 single account** OR **up to 1,000 Flash-Sale accounts in 1 request** (`count > 1`, `accounts: [...]`, or JSON array `[...]`) |
| `GET` | `/api/accounts/{protocol}` | List accounts (`?status=active&search=alice&page=1&per_page=50`) |
| `PUT` | `/api/accounts/{protocol}` | Batch renew multiple accounts (`{"usernames": [...], "days": 30}`) |
| `DELETE` | `/api/accounts/{protocol}` | Batch delete multiple accounts (`{"usernames": [...]}`) |
| `GET` | `/api/accounts/{protocol}/{username}` | Get single account with real-time live bandwidth usage |
| `PUT` | `/api/accounts/{protocol}/{username}` | Update quota, IP limit, password, note, or extend days |
| `DELETE` | `/api/accounts/{protocol}/{username}` | Soft-delete single account & terminate active user sessions |
| `POST` | `/api/accounts/{protocol}/{username}/renew` | Renew single account validity (`{"days": 30, "reset_quota": true}`) |
| `POST` | `/api/accounts/{protocol}/{username}/recovery` | Recover soft-deleted or suspended account |
| `POST` | `/api/accounts/{protocol}/{username}/suspend` | Suspend account & disconnect sessions (`{"reason": "abuse"}`) |
| `POST` | `/api/accounts/{protocol}/{username}/unsuspend` | Restore suspended account to `active` |
| `POST` | `/api/accounts/{protocol}/{username}/reset-quota` | Reset `used_bytes` (and `ssh_proto_usage`) to `0` |
| `POST` | `/api/accounts/{protocol}/{username}/kick` | Disconnect active user sessions without restarting global daemons |

- **Optional Idempotency Header (`POST /api/accounts/{protocol}`)**: `X-Idempotency-Key: <unique-order-id>` — caches the `201 Created` payload for 15 minutes so network retries never create duplicate accounts (returns `X-Idempotent-Replay: true`).

### Mode 1 — Standard Single Account Creation (`POST /api/accounts/{protocol}`)
100% compatible with standard single-account panels and Telegram bots (`?include_config=true` optional to embed connection links):
```json
{
  "username": "premium_user01",
  "password": "MySecurePassword123",
  "secret": "",
  "quota": 100,
  "limit_ip": 2,
  "days": 30,
  "note": "Order #98122"
}
```
*(Note: `password` is required for `ssh` and `noobz`. `secret` is optional for `vless`, `vmess`, and `trojan` — auto-generated via CSPRNG if omitted.)*

### Mode 2 — Flash-Sale Auto-Generator Mode (`POST /api/accounts/{protocol}`)
Pass `"count": N` (`2..1000`) on the exact same `POST /api/accounts/{protocol}` endpoint to provision hundreds of accounts in **1 single Xray config pass + 1 Xray reload + 1 SQLite WAL transaction** (`prefix` or `username` acts as the username prefix):
```json
{
  "count": 500,
  "prefix": "flash11_",
  "quota": 50,
  "limit_ip": 2,
  "days": 30,
  "include_config": true
}
```

### Mode 3 — Flash-Sale Explicit Array Mode (`POST /api/accounts/{protocol}`)
Send either `{"accounts": [...]}` or a top-level JSON array `[ {...}, {...} ]` to `POST /api/accounts/{protocol}`:
```json
{
  "days": 30,
  "quota": 100,
  "limit_ip": 2,
  "accounts": [
    { "username": "buyer_001", "password": "StrongPass001!" },
    { "username": "buyer_002", "password": "StrongPass002!" }
  ]
}
```

#### Flash-Sale Bulk Response (`201 Created`)
```json
{
  "success": true,
  "code": 201,
  "message": "Accounts created successfully",
  "data": {
    "protocol": "vless",
    "requested_count": 500,
    "created_count": 500,
    "failed_count": 0,
    "duration_ms": 48,
    "idempotency_key": "flash-order-0001",
    "accounts": [
      {
        "account": {
          "id": 1,
          "protocol": "vless",
          "username": "flash11_a1b2_0001",
          "secret": "d1a4e7c0-9b1f-4f5a-9c3d-112233445566",
          "quota_bytes": 53687091200,
          "used_bytes": 0,
          "limit_ip": 2,
          "expired_at": "2026-12-02T19:50:00Z",
          "status": "active"
        },
        "config": {
          "protocol": "vless",
          "username": "flash11_a1b2_0001",
          "link": "vless://d1a4e7c0-...@vpn.yourdomain.com:443?...",
          "transports": {
            "ws_tls": "vless://...",
            "ws_ntls": "vless://...",
            "hu_tls": "vless://...",
            "hu_ntls": "vless://...",
            "xhttp_tls": "vless://...",
            "xhttp_ntls": "vless://...",
            "grpc_tls": "vless://..."
          }
        }
      }
    ]
  }
}
```

### Batch Renew (`PUT /api/accounts/{protocol}`) & Batch Delete (`DELETE /api/accounts/{protocol}`)
```json
// PUT /api/accounts/vless
{
  "usernames": ["buyer_001", "buyer_002"],
  "days": 30
}

// DELETE /api/accounts/vless
{
  "usernames": ["buyer_001", "buyer_002", "buyer_003"]
}
```

---

## 7. Trial Account Endpoints (Single & Bulk on `POST /api/trials/{protocol}`)

Supports exact minute, hour, and day durations (`30m`, `1h`, `6h`, `1d`) on the single standard endpoint `POST /api/trials/{protocol}`.

### Single Trial (`POST /api/trials/{protocol}`)
```json
{
  "duration": "1h",
  "quota": 5,
  "limit_ip": 2
}
```

### Bulk Trials (`POST /api/trials/{protocol}` with `count > 1`)
```json
{
  "count": 100,
  "prefix": "promo_",
  "duration": "2h",
  "quota": 5,
  "limit_ip": 1
}
```

---

## 8. Connection Config & OpenVPN Profile Endpoints

- `GET /api/config/{protocol}/{username}?domain=custom.domain.com` — Returns full multi-transport URIs (`ws_tls`, `ws_ntls`, `hu_tls`, `hu_ntls`, `xhttp_tls`, `xhttp_ntls`, `grpc_tls`), SSH HTTP/TLS payloads, SlowDNS nameserver + public key, and complete `ports` matrix.
- `GET /api/config/openvpn/{username}` — Downloads the `.ovpn` profile (`application/x-openvpn-profile`).

---

## 9. SSH All-Protocol Quota & Multi-Protocol Quota Endpoints

Tracks and enforces bandwidth quota across **ALL 6 SSH sub-protocols**:
1. **`openssh`**: Direct OpenSSH (`:22`, `:3303`)
2. **`dropbear`**: Direct Dropbear (`:109`, `:143`)
3. **`ssh_ssl`**: Direct SSH over SSL/TLS via HAProxy (`:443`, `:8443` -> `:109`)
4. **`ssh_ws`**: SSH over WebSocket HTTP & TLS (`:80`, `:8080`, `:8888`, `:443`)
5. **`slowdns`**: SlowDNS / DNSTT Stealth Tunnel (`:53`, `:5300` UDP -> `:109`)
6. **`openvpn`**: OpenVPN TCP/UDP (`:1194`, `:2200`)

### `GET /api/quota/ssh`
Returns server-wide SSH All-Protocol traffic totals + per-user quota status and sub-protocol breakdown.

### `GET /api/quota/ssh/{username}`
Returns detailed per-subprotocol RX/TX/Total quota usage for a specific SSH user:
```json
{
  "success": true,
  "code": 200,
  "message": "SSH All-Protocol user quota retrieved",
  "data": {
    "username": "budi_ssh",
    "status": "active",
    "quota_bytes": 107374182400,
    "quota_human": "100.00 GB",
    "used_bytes": 2993057792,
    "used_human": "2.79 GB",
    "remaining_bytes": 104381124608,
    "remaining_human": "97.21 GB",
    "usage_percent": 2.7,
    "limit_ip": 3,
    "active_ip_count": 2,
    "active_protocols": ["openvpn", "ssh_ssl"],
    "expired_at": "2026-12-02T19:50:00Z",
    "breakdown": {
      "openssh":  { "sub_protocol": "openssh",  "rx_bytes": 104857600,  "tx_bytes": 52428800,  "total_bytes": 157286400,  "human_total": "150.00 MB" },
      "dropbear": { "sub_protocol": "dropbear", "rx_bytes": 0,          "tx_bytes": 0,         "total_bytes": 0,          "human_total": "0 B" },
      "ssh_ssl":  { "sub_protocol": "ssh_ssl",  "rx_bytes": 536870912,  "tx_bytes": 268435456, "total_bytes": 805306368,  "human_total": "768.00 MB" },
      "ssh_ws":   { "sub_protocol": "ssh_ws",   "rx_bytes": 268435456,  "tx_bytes": 134217728, "total_bytes": 402653184,  "human_total": "384.00 MB" },
      "slowdns":  { "sub_protocol": "slowdns",  "rx_bytes": 10485760,   "tx_bytes": 5242880,   "total_bytes": 15728640,   "human_total": "15.00 MB" },
      "openvpn":  { "sub_protocol": "openvpn",  "rx_bytes": 1073741824, "tx_bytes": 536870912, "total_bytes": 1610612736, "human_total": "1.50 GB" },
      "total_rx": 1994391552,
      "total_tx": 997195776,
      "total_bytes": 2991587328,
      "human_total": "2.79 GB"
    }
  }
}
```

### `GET /api/quota/{protocol}` & `GET /api/quota/{protocol}/{username}`
Works across `vless`, `vmess`, `trojan`, `noobz`, and `ssh`.

---

## 10. Live Session Monitor, Accessed Apps/Domains, ISP & GeoIP Telemetry

Provides real-time visibility into connected users across every protocol, including:
- **Apps & Domains Currently Accessed** (classifies 65+ apps across Streaming, Social, Messaging, Gaming, AI, E-Commerce, Cloud/CDN: *YouTube, Netflix, TikTok, Instagram, WhatsApp, Telegram, Discord, ChatGPT/OpenAI, Claude, Mobile Legends, PUBG, Roblox, Shopee, Tokopedia*, etc.)
- **Exact Protocol & Transport Used** (`openssh`, `dropbear`, `ssh_ssl`, `ssh_ws`, `slowdns`, `openvpn`, `vless-ws`, `vless-grpc`, `vless-xhttp`, `vless-hu`, `noobz`)
- **ISP / ASN & Geographic Location** (3-tier free GeoIP lookup: `ip-api.com/batch` -> `ipwho.is` -> `freeipapi.com` with 24h RAM + `/run/autoscript-geoip.cache` caching)

### Endpoints
- `GET /api/monitor` — Unified server-wide live report across ALL 5 protocols (`total_online_users`, `total_connections`, `by_protocol_count`, `top_apps`, `protocols`)
- `GET /api/monitor/{protocol}` — Live connected users for `ssh`, `vless`, `vmess`, `trojan`, `noobz`, or `all`
- `GET /api/monitor/{protocol}/{username}` *(or `/activity`)* — Deep real-time telemetry for a single user

### Example Response (`GET /api/monitor/vless/{username}/activity`)
```json
{
  "success": true,
  "code": 200,
  "message": "User live session & app telemetry retrieved",
  "data": {
    "protocol": "vless",
    "username": "premium_user01",
    "status": "active",
    "ip_count": 2,
    "ip_limit": 2,
    "ips": ["198.51.100.25", "203.0.113.10"],
    "active_protocols": ["vless"],
    "transports": ["vless-grpc", "vless-ws"],
    "isps": ["Biznet Networks", "Telkomsel Indonesia"],
    "locations": [
      {
        "ip": "203.0.113.10",
        "country": "Indonesia",
        "country_code": "ID",
        "city": "Jakarta",
        "isp": "Telkomsel Indonesia",
        "asn": "AS23693"
      }
    ],
    "accessed_apps": ["YouTube", "ChatGPT / OpenAI", "Netflix"],
    "accessed_domains": ["rr1---sn.googlevideo.com", "api.openai.com", "www.netflix.com"],
    "app_activities": [
      {
        "app": "YouTube",
        "category": "streaming",
        "domain": "rr1---sn.googlevideo.com",
        "protocol": "tcp",
        "hits": 14,
        "last_seen": "2026/11/02 19:49:52"
      }
    ],
    "used_bytes": 5368709120,
    "used_human": "5.00 GB",
    "quota_bytes": 107374182400,
    "quota_human": "100.00 GB",
    "remaining_bytes": 102005473280,
    "usage_percent": 5.0,
    "expired_at": "2026-12-02T19:50:00Z"
  }
}
```

---

## 11. System Info, Bandwidth, Services, Rocky Optimization & Audit

| Method | Endpoint | Description |
|---|---|---|
| `GET` | `/api/status` | Real-time status of all 16 VPN & quota/limiter daemons |
| `GET` | `/api/system/info` | Pure-Go CPU, RAM, ZRAM, Conntrack, TCP Congestion (`bbr`), Kernel, and Rocky Tier (`1GB-EXTREME`..`8GB+-ENTERPRISE`) |
| `GET` | `/api/system/services` | Alias of `/api/status` |
| `POST` | `/api/system/services/{service}/{action}` | Start/stop/restart an allowlisted VPN daemon (`start`, `stop`, `restart`) |
| `GET` | `/api/system/ports` | Complete TCP/UDP server port matrix |
| `GET` | `/api/system/slowdns` | SlowDNS service state, nameserver, and public key |
| `POST` | `/api/system/optimize` | Apply Rocky Linux extreme kernel/ZRAM tuning & firewall/SELinux healing |
| `POST` | `/api/system/cleanup` | Mark past-due accounts `expired` & purge old soft-deleted rows |
| `GET` | `/api/system/audit-logs?limit=100` | Recent administrative & bulk provisioning audit log entries |
| `GET` | `/api/bandwidth` | Interface RX/TX totals + daily & monthly history (`vnstat --json` with `/proc/net/dev` fallback) |

---

## 12. Environment Configuration Reference

| Variable | Default | Description |
|---|---|---|
| `API_LISTEN` | `127.0.0.1:9000` | HTTP bind address |
| `API_SECURITY_MODE` | `strict` | `strict` (all 5 SHA-256 layers required) or `compat` |
| `API_KEY_FILE` | `/etc/api/key` | Default Bearer token file synced with `api.db` |
| `API_SECRET_FILE` | `/etc/api/secret` | 256-bit HMAC secret key file for Layer-5 & mutual response signing |
| `API_MAX_SKEW_SEC` | `300` | Maximum allowed `X-Timestamp` drift in seconds |
| `API_ALLOWED_IPS` | *(empty = all)* | Optional comma-separated IP/CIDR allowlist |
| `API_MAX_CONCURRENCY` | *(auto by RAM)* | `65536` (1GB RAM), `262144` (2-4GB), `1048576` (>4GB) |
| `API_MAX_BULK_SIZE` | `1000` | Maximum accounts per Flash-Sale bulk request |
| `RATE_LIMIT` | `5000` | Unauthenticated requests per window per IP |
| `AUTH_RATE_LIMIT` | `100000` | Authenticated SHA-256 verified requests per window per IP |
| `RATE_LIMIT_WINDOW` | `60` | Rate limit window in seconds |

---

## 13. Shell Pipe API Compatibility Matrix

All 25 pipe-based CLI handlers in `/usr/local/sbin/api-<action>-<proto>` (`scripts/api/*.sh`) remain available for local SSH/stdin automation:
- `add-{ssh,vless,vmess,trojan,noobz}`
- `trial-{ssh,vless,vmess,trojan,noobz}`
- `delete-{ssh,vless,vmess,trojan,noobz}`
- `renew-{ssh,vless,vmess,trojan,noobz}`
- `recovery-{ssh,vless,vmess,trojan,noobz}`
