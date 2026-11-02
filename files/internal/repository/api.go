package repository

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"os"
	"strings"
	"time"
)

// APILogEntry represents a buffered HTTP audit log record.
type APILogEntry struct {
	Timestamp int64
	Method    string
	Path      string
	IP        string
	Status    int
	LatencyMs float64
}

// APIRepository defines the interface for API database operations.
type APIRepository interface {
	// Token management
	CreateToken(ctx context.Context, name string) (string, error)
	ValidateToken(ctx context.Context, token string) (bool, error)
	TouchTokenLastUsed(ctx context.Context, token string, unixTs int64) error
	RevokeToken(ctx context.Context, token string) error
	ListTokens(ctx context.Context) ([]TokenInfo, error)
	SyncKeyFile(ctx context.Context, keyFile string) (string, error)

	// Legacy SQLite rate limiting helpers (kept for interface compatibility)
	GetRequestCount(ctx context.Context, ip string, window int) (int, error)
	IncrementRequestCount(ctx context.Context, ip string) error
	CleanupRateLimits(ctx context.Context) error

	// API audit log
	LogRequest(ctx context.Context, method, path, ip string, status int, latency time.Duration) error
	LogRequestBatch(ctx context.Context, entries []APILogEntry) error
	PruneLogs(ctx context.Context, maxRows int) error
}

// TokenInfo represents an API token.
type TokenInfo struct {
	Name      string    `json:"name"`
	Token     string    `json:"token"`
	CreatedAt time.Time `json:"created_at"`
	LastUsed  time.Time `json:"last_used,omitempty"`
}

// apiRepository implements APIRepository.
type apiRepository struct {
	db *sql.DB
}

// NewAPIRepository creates a new APIRepository.
func NewAPIRepository(db *sql.DB) APIRepository {
	return &apiRepository{db: db}
}

// NewAPIRepositoryImpl creates a new apiRepository (implementation).
func NewAPIRepositoryImpl(db *sql.DB) *apiRepository {
	return &apiRepository{db: db}
}

// InitSchema creates the API database schema with WAL concurrency pragmas.
func (r *apiRepository) InitSchema() error {
	schema := `
	PRAGMA journal_mode=WAL;
	PRAGMA synchronous=NORMAL;
	PRAGMA temp_store=MEMORY;
	PRAGMA busy_timeout=8000;

	CREATE TABLE IF NOT EXISTS tokens (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		name TEXT NOT NULL,
		token TEXT NOT NULL UNIQUE,
		created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		last_used INTEGER NOT NULL DEFAULT 0
	);

	CREATE TABLE IF NOT EXISTS rate_limits (
		ip TEXT NOT NULL,
		timestamp INTEGER NOT NULL,
		PRIMARY KEY (ip, timestamp)
	);

	CREATE TABLE IF NOT EXISTS api_log (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		ts INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		method TEXT NOT NULL,
		path TEXT NOT NULL,
		ip TEXT NOT NULL,
		status INTEGER NOT NULL,
		latency_ms REAL NOT NULL
	);

	CREATE INDEX IF NOT EXISTS idx_rate_limits_ip ON rate_limits(ip);
	CREATE INDEX IF NOT EXISTS idx_api_log_ts ON api_log(ts);
	`
	_, err := r.db.Exec(schema)
	return err
}

// SyncKeyFile ensures that any token present in /etc/api/key is registered in the tokens table,
// or if no tokens exist anywhere, generates a default token and writes /etc/api/key (0600).
func (r *apiRepository) SyncKeyFile(ctx context.Context, keyFile string) (string, error) {
	var fileToken string
	if keyFile != "" {
		if data, err := os.ReadFile(keyFile); err == nil {
			fileToken = strings.TrimSpace(strings.SplitN(string(data), "\n", 2)[0])
		}
	}

	if len(fileToken) >= 16 {
		_, _ = r.db.ExecContext(ctx,
			`INSERT OR IGNORE INTO tokens (name, token, created_at) VALUES ('keyfile', ?, strftime('%s','now'))`,
			fileToken,
		)
	}

	tokens, err := r.ListTokens(ctx)
	if err != nil {
		return "", err
	}
	if len(tokens) > 0 {
		if keyFile != "" && fileToken == "" {
			_ = os.WriteFile(keyFile, []byte(tokens[0].Token+"\n"), 0600)
		}
		return tokens[0].Token, nil
	}

	tok, err := r.CreateToken(ctx, "default")
	if err != nil {
		return "", err
	}
	if keyFile != "" {
		_ = os.WriteFile(keyFile, []byte(tok+"\n"), 0600)
	}
	return tok, nil
}

// CreateToken generates and stores a new API token.
func (r *apiRepository) CreateToken(ctx context.Context, name string) (string, error) {
	token, err := generateToken()
	if err != nil {
		return "", fmt.Errorf("generate token: %w", err)
	}

	query := `INSERT INTO tokens (name, token) VALUES (?, ?)`
	_, err = r.db.ExecContext(ctx, query, name, token)
	if err != nil {
		return "", fmt.Errorf("insert token: %w", err)
	}

	return token, nil
}

// ValidateToken checks if a token is valid directly in SQLite (used as fallback; hot path uses atomic memory cache).
func (r *apiRepository) ValidateToken(ctx context.Context, token string) (bool, error) {
	query := `SELECT COUNT(*) FROM tokens WHERE token = ?`
	var count int
	err := r.db.QueryRowContext(ctx, query, token).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("validate token: %w", err)
	}
	return count > 0, nil
}

// TouchTokenLastUsed updates last_used asynchronously from background flushers.
func (r *apiRepository) TouchTokenLastUsed(ctx context.Context, token string, unixTs int64) error {
	_, err := r.db.ExecContext(ctx, `UPDATE tokens SET last_used = ? WHERE token = ?`, unixTs, token)
	return err
}

// RevokeToken deletes a token.
func (r *apiRepository) RevokeToken(ctx context.Context, token string) error {
	query := `DELETE FROM tokens WHERE token = ?`
	result, err := r.db.ExecContext(ctx, query, token)
	if err != nil {
		return fmt.Errorf("revoke token: %w", err)
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		return fmt.Errorf("token not found")
	}

	return nil
}

// ListTokens returns all tokens.
func (r *apiRepository) ListTokens(ctx context.Context) ([]TokenInfo, error) {
	query := `SELECT name, token, created_at, last_used FROM tokens ORDER BY id DESC`
	rows, err := r.db.QueryContext(ctx, query)
	if err != nil {
		return nil, fmt.Errorf("list tokens: %w", err)
	}
	defer rows.Close()

	var tokens []TokenInfo
	for rows.Next() {
		var t TokenInfo
		var createdAt, lastUsed int64
		if err := rows.Scan(&t.Name, &t.Token, &createdAt, &lastUsed); err != nil {
			return nil, fmt.Errorf("scan token: %w", err)
		}
		t.CreatedAt = time.Unix(createdAt, 0)
		if lastUsed > 0 {
			t.LastUsed = time.Unix(lastUsed, 0)
		}
		tokens = append(tokens, t)
	}

	return tokens, nil
}

// GetRequestCount returns the number of requests from an IP within the window.
func (r *apiRepository) GetRequestCount(ctx context.Context, ip string, window int) (int, error) {
	cutoff := time.Now().Add(-time.Duration(window) * time.Second).Unix()
	query := `SELECT COUNT(*) FROM rate_limits WHERE ip = ? AND timestamp >= ?`
	var count int
	err := r.db.QueryRowContext(ctx, query, ip, cutoff).Scan(&count)
	if err != nil {
		return 0, fmt.Errorf("get request count: %w", err)
	}
	return count, nil
}

// IncrementRequestCount records a request from an IP.
func (r *apiRepository) IncrementRequestCount(ctx context.Context, ip string) error {
	query := `INSERT OR IGNORE INTO rate_limits (ip, timestamp) VALUES (?, strftime('%s','now'))`
	_, err := r.db.ExecContext(ctx, query, ip)
	if err != nil {
		return fmt.Errorf("increment request count: %w", err)
	}
	return nil
}

// CleanupRateLimits removes old rate limit entries.
func (r *apiRepository) CleanupRateLimits(ctx context.Context) error {
	query := `DELETE FROM rate_limits WHERE timestamp < strftime('%s','now', '-5 minutes')`
	_, err := r.db.ExecContext(ctx, query)
	return err
}

// LogRequest logs a single API request.
func (r *apiRepository) LogRequest(ctx context.Context, method, path, ip string, status int, latency time.Duration) error {
	query := `INSERT INTO api_log (method, path, ip, status, latency_ms) VALUES (?, ?, ?, ?, ?)`
	_, err := r.db.ExecContext(ctx, query, method, path, ip, status, latency.Seconds()*1000)
	if err != nil {
		return fmt.Errorf("log request: %w", err)
	}
	return nil
}

// LogRequestBatch writes buffered API log entries in a single fast SQLite transaction.
func (r *apiRepository) LogRequestBatch(ctx context.Context, entries []APILogEntry) error {
	if len(entries) == 0 {
		return nil
	}

	tx, err := r.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin log batch tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.PrepareContext(ctx, `INSERT INTO api_log (ts, method, path, ip, status, latency_ms) VALUES (?, ?, ?, ?, ?, ?)`)
	if err != nil {
		return fmt.Errorf("prepare log batch: %w", err)
	}
	defer stmt.Close()

	for _, e := range entries {
		ts := e.Timestamp
		if ts == 0 {
			ts = time.Now().Unix()
		}
		if _, err := stmt.ExecContext(ctx, ts, e.Method, e.Path, e.IP, e.Status, e.LatencyMs); err != nil {
			return fmt.Errorf("exec log batch item: %w", err)
		}
	}

	return tx.Commit()
}

// PruneLogs keeps api_log bounded on low-storage 1GB VPS instances.
func (r *apiRepository) PruneLogs(ctx context.Context, maxRows int) error {
	if maxRows <= 0 {
		maxRows = 10000
	}
	query := `DELETE FROM api_log WHERE id NOT IN (SELECT id FROM api_log ORDER BY id DESC LIMIT ?)`
	_, err := r.db.ExecContext(ctx, query, maxRows)
	return err
}

// generateToken creates a random 32-byte (64-hex) CSPRNG token.
func generateToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}
