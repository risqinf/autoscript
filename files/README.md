# Autoscript VPN Enterprise API Server (`v5.5.0`)

High-throughput, security-hardened Go RESTful API daemon for Autoscript VPN on **Rocky Linux 9** (SSH All-Protocol, VLESS, VMESS, Trojan, NoobzVPN, SlowDNS, OpenVPN).

## Highlights

- **5-Layer Strict SHA-256 Request Verification** (`Authorization: Bearer` SHA-256 digest + `X-Content-SHA256` + `X-Timestamp` + `X-Nonce` 256-shard anti-replay + `X-Signature` canonical HMAC-SHA256) & **Mutual Server Response Signatures** (`X-Server-Signature`).
- **Million-Request Concurrency**: Atomic in-memory token digests, 256-shard rate limiter, `Singleflight` request coalescing + micro-TTL snapshots, async ring-buffered SQLite audit logger, and separated SQLite WAL reader/writer connection pools.
- **Flash-Sale Bulk Provisioning**: Create, renew, or delete up to **1,000 accounts in 1 single HTTP request** with single-pass native Go Xray JSON mutation + `X-Idempotency-Key` support.
- **SSH All-Protocol Quota & Deep Live Telemetry**: Real-time quota & session tracking across OpenSSH (`22, 3303`), Dropbear (`109, 143`), Direct SSH SSL/TLS (`443, 8443`), SSH-WS (`80, 8080, 8888, 443`), SlowDNS (`53, 5300`), and OpenVPN (`1194`), enriched with **Accessed Apps/Domains**, **ISP/ASN**, and **GeoIP Location**.

## Package Architecture

```
files/
├── cmd/server/main.go               # Entrypoint, WAL pool separation & DI wiring
├── internal/
│   ├── cache/singleflight.go        # Singleflight snapshot cache & sharded IdempotencyStore
│   ├── config/config.go             # RAM-tiered configuration & secret loader
│   ├── security/verifier.go         # 5-Layer SHA-256 verifier & mutual response signer
│   ├── middleware/middleware.go     # Auth, 256-shard rate limiter & async batch logger
│   ├── model/                       # Typed request, response, quota & telemetry models
│   ├── validator/validator.go       # Strict allowlist & injection-proof validators
│   ├── repository/                  # Separated read/write SQLite WAL repositories
│   ├── service/                     # Account bulk engine, native Xray mutator, GeoIP & App detector
│   ├── handler/                     # FastHTTP handlers
│   └── router/router.go             # `/api` & `/api/v1` route registration
└── api-server.service               # Systemd unit file
```

## Build & Test

```bash
cd files
go vet ./...
go test -race -v ./...
CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.Version=v5.5.0" -o api-server ./cmd/server/main.go
```

For full endpoint schemas and multi-language SHA-256 signing examples, see [`../docs/API.md`](../docs/API.md).
