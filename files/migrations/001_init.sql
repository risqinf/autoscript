-- API Database Schema
-- This database stores API-specific data (tokens, rate limits, audit logs)

-- Tokens table for API authentication
CREATE TABLE IF NOT EXISTS tokens (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    token TEXT NOT NULL UNIQUE,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    last_used INTEGER NOT NULL DEFAULT 0
);

-- Rate limiting table
CREATE TABLE IF NOT EXISTS rate_limits (
    ip TEXT NOT NULL,
    timestamp INTEGER NOT NULL,
    PRIMARY KEY (ip, timestamp)
);

-- API audit log
CREATE TABLE IF NOT EXISTS api_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts INTEGER NOT NULL DEFAULT (strftime('%s','now')),
    method TEXT NOT NULL,
    path TEXT NOT NULL,
    ip TEXT NOT NULL,
    status INTEGER NOT NULL,
    latency_ms REAL NOT NULL
);

-- Indexes for performance
CREATE INDEX IF NOT EXISTS idx_tokens_token ON tokens(token);
CREATE INDEX IF NOT EXISTS idx_rate_limits_ip ON rate_limits(ip);
CREATE INDEX IF NOT EXISTS idx_rate_limits_timestamp ON rate_limits(timestamp);
CREATE INDEX IF NOT EXISTS idx_api_log_ts ON api_log(ts);
CREATE INDEX IF NOT EXISTS idx_api_log_ip ON api_log(ip);
