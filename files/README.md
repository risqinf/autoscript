# Autoscript VPN API Server

RESTful API server for managing VPN accounts (SSH, VLESS, VMESS, Trojan).

## Tech Stack

- **Language**: Go 1.22+
- **HTTP**: FastHTTP (high-performance)
- **Database**: SQLite (modernc.org/sqlite, no CGO)
- **Architecture**: Clean Architecture (handler → service → repository)

## Project Structure

```
files/
├── cmd/server/main.go          # Entry point, DI wiring
├── internal/
│   ├── config/                 # Configuration loader
│   ├── model/                  # Data structures
│   ├── handler/                # HTTP request handlers
│   ├── service/                # Business logic
│   ├── repository/             # Database access
│   ├── middleware/              # Auth, logging, rate limiting
│   ├── router/                 # Route definitions
│   └── validator/              # Input validation
├── migrations/                 # Database migrations
└── api-server.service          # Systemd service unit
```

## API Endpoints

### Health
- `GET /api/health` - Health check (no auth)

### Accounts
- `POST /api/accounts/{protocol}` - Create account
- `GET /api/accounts/{protocol}` - List accounts
- `GET /api/accounts/{protocol}/{username}` - Get account
- `PUT /api/accounts/{protocol}/{username}` - Update account
- `DELETE /api/accounts/{protocol}/{username}` - Delete account
- `POST /api/accounts/{protocol}/{username}/renew` - Renew account
- `POST /api/accounts/{protocol}/{username}/recovery` - Recover account

### Trials
- `POST /api/trials/{protocol}` - Create trial account

### Config
- `GET /api/config/{protocol}/{username}` - Get config link
- `GET /api/config/openvpn/{username}` - Download .ovpn file

### Monitoring
- `GET /api/status` - Service status
- `GET /api/monitor/{protocol}` - Login monitor
- `GET /api/bandwidth` - Bandwidth stats

### System
- `GET /api/system/info` - System information
- `GET /api/system/services` - Service list

## Authentication

All endpoints (except `/api/health`) require Bearer token authentication:

```bash
curl -H "Authorization: Bearer <token>" https://domain/api/accounts/ssh
```

## Response Format

### Success
```json
{
  "success": true,
  "code": 200,
  "message": "Account retrieved successfully",
  "data": { ... }
}
```

### Error
```json
{
  "success": false,
  "code": 404,
  "error": {
    "type": "NOT_FOUND",
    "message": "Account not found",
    "details": []
  }
}
```

## Build

```bash
cd files
go build -o api-server ./cmd/server
```

## Install

```bash
# Build
cd files
go build -o /usr/local/bin/api-server ./cmd/server

# Install systemd service
cp api-server.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable api-server --now
```

## Configuration

Environment variables (with defaults):

| Variable | Default | Description |
|----------|---------|-------------|
| `API_LISTEN` | `127.0.0.1:9000` | Listen address |
| `API_DB_PATH` | `/etc/api/api.db` | API database path |
| `MAIN_DB_PATH` | `/etc/xray/xray.db` | Main database path |
| `RATE_LIMIT` | `100` | Requests per window |
| `RATE_LIMIT_WINDOW` | `60` | Window in seconds |

## Databases

- **API Database** (`/etc/api/api.db`): Tokens, rate limits, audit logs
- **Main Database** (`/etc/xray/xray.db`): Account data (shared with bash scripts)

## Security

- Bearer token authentication
- Rate limiting per IP
- Input validation
- Constant-time token comparison
- No sensitive data in logs
