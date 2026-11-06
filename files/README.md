# Autoscript VPN Enterprise API Server (`v5.6.1`)

Zero-downtime, high-concurrency, security-hardened Go RESTful API daemon for Autoscript VPN on **Enterprise Linux 9 & 10** (**Rocky Linux 9–10**, **RHEL 9–10**, **AlmaLinux 9–10**, **Oracle Linux 9–10**).

## Highlights

- **Zero-Downtime Simultaneous Order Burst Engine**: Handles **100+ simultaneous buyer requests** (`POST /api/accounts/{protocol}` or `POST /api/accounts`) with zero lock errors via **Leader-Follower Group-Commit Xray Write Coalescing**, **Cross-Process `flock` Batch `/etc/shadow` Mutation** (`ShadowMutator`), **DB-First Atomic Reservation**, and **SQLite WAL `busy_timeout(15000)`** across all pooled connections.
- **Complete Standard REST Endpoints & Auto-Detect User Login**:
  - **Create**: `POST /api/accounts/{protocol}` & `POST /api/accounts` (single & Flash-Sale bulk up to 1,000 accounts/request).
  - **Delete**: `DELETE /api/accounts/{protocol}/{username}`, `POST /api/accounts/{protocol}/{username}/delete`, `DELETE /api/accounts/{protocol}`, `DELETE /api/users/{username}`, `POST /api/users/{username}/delete`.
  - **Renew**: `POST /api/accounts/{protocol}/{username}/renew`, `PUT /api/accounts/{protocol}`, `POST /api/users/{username}/renew`.
  - **Auto-Detect User Login & All Information**: `GET /api/users/{username}/login`, `GET /api/users/{username}`, and `GET /api/monitor/users/{username}` — automatically detects user protocol(s) (`ssh`, `vless`, `vmess`, `trojan`, `noobz`), active sub-protocols/transports, connected IPs, ISPs, GeoIP locations, accessed apps/domains, quota breakdown, and connection `config` links.
- **5-Layer Strict SHA-256 Request Verification** (`Authorization: Bearer` SHA-256 digest + `X-Content-SHA256` + `X-Timestamp` + `X-Nonce` 256-shard anti-replay + `X-Signature` canonical HMAC-SHA256) & **Mutual Server Response Signatures** (`X-Server-Signature`).

## Package Architecture

```
files/
├── cmd/server/main.go               # Entrypoint, WAL pool separation & DI wiring
├── internal/
│   ├── cache/singleflight.go        # Singleflight snapshot cache & sharded IdempotencyStore
│   ├── config/config.go             # RAM-tiered configuration, SQLiteDSN pragmas & secret loader
│   ├── security/verifier.go         # 5-Layer SHA-256 verifier & mutual response signer
│   ├── middleware/middleware.go     # Auth, 256-shard rate limiter & async batch logger
│   ├── model/                       # Typed request, response, quota & auto-detect telemetry models
│   ├── validator/validator.go       # Strict allowlist & injection-proof validators
│   ├── repository/                  # Separated read/write SQLite WAL repositories with race guards
│   ├── service/                     # Coalesced Xray mutator, flock ShadowMutator, GeoIP & App detector
│   ├── handler/                     # FastHTTP handlers (standard & auto-detect user endpoints)
│   └── router/router.go             # `/api` & `/api/v1` route registration
└── api-server.service               # Hardened systemd unit (StartLimitIntervalSec=0, OOMScoreAdjust=-900)
```

## Build & Test

```bash
cd files
go vet ./...
go test -v ./...
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.Version=v5.6.1" -o api-server ./cmd/server/main.go
```

For full endpoint schemas and multi-language SHA-256 signing examples, see [`../docs/API.md`](../docs/API.md).
