package repository

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"time"
)

// APIRepository defines the interface for API database operations.
type APIRepository interface {
	// Token management
	CreateToken(ctx context.Context, name string) (string, error)
	ValidateToken(ctx context.Context, token string) (bool, error)
	RevokeToken(ctx context.Context, token string) error
	ListTokens(ctx context.Context) ([]TokenInfo, error)

	// Rate limiting
	GetRequestCount(ctx context.Context, ip string, window int) (int, error)
	IncrementRequestCount(ctx context.Context, ip string) error
	CleanupRateLimits(ctx context.Context) error

	// API audit log
	LogRequest(ctx context.Context, method, path, ip string, status int, latency time.Duration) error
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

// InitSchema creates the API database schema.
func (r *apiRepository) InitSchema() error {
	schema := `
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

// ValidateToken checks if a token is valid.
func (r *apiRepository) ValidateToken(ctx context.Context, token string) (bool, error) {
	query := `SELECT COUNT(*) FROM tokens WHERE token = ?`
	var count int
	err := r.db.QueryRowContext(ctx, query, token).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("validate token: %w", err)
	}

	if count > 0 {
		// Update last_used
		update := `UPDATE tokens SET last_used = strftime('%s','now') WHERE token = ?`
		_, _ = r.db.ExecContext(ctx, update, token)
	}

	return count > 0, nil
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
	query := `SELECT name, token, created_at, last_used FROM tokens ORDER BY created_at DESC`
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
	query := `INSERT INTO rate_limits (ip, timestamp) VALUES (?, strftime('%s','now'))`
	_, err := r.db.ExecContext(ctx, query, ip)
	if err != nil {
		return fmt.Errorf("increment request count: %w", err)
	}

	return nil
}

// CleanupRateLimits removes old rate limit entries (called periodically).
func (r *apiRepository) CleanupRateLimits(ctx context.Context) error {
	query := `DELETE FROM rate_limits WHERE timestamp < strftime('%s','now', '-5 minutes')`
	_, err := r.db.ExecContext(ctx, query)
	return err
}

// LogRequest logs an API request.
func (r *apiRepository) LogRequest(ctx context.Context, method, path, ip string, status int, latency time.Duration) error {
	query := `INSERT INTO api_log (method, path, ip, status, latency_ms) VALUES (?, ?, ?, ?, ?)`
	_, err := r.db.ExecContext(ctx, query, method, path, ip, status, latency.Seconds()*1000)
	if err != nil {
		return fmt.Errorf("log request: %w", err)
	}
	return nil
}

// generateToken creates a random 32-byte hex token.
func generateToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return hex.EncodeToString(bytes), nil
}
