package repository

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/risqinf/autoscript-api/internal/model"
)

// AccountRepository defines the interface for account database operations.
type AccountRepository interface {
	GetByUsername(ctx context.Context, protocol, username string) (*model.Account, error)
	GetByUsernameIncludingDeleted(ctx context.Context, protocol, username string) (*model.Account, error)
	Exists(ctx context.Context, protocol, username string) (bool, error)
	SecretInUse(ctx context.Context, secret string) (bool, error)
	Create(ctx context.Context, account *model.Account) error
	Update(ctx context.Context, account *model.Account) error
	Delete(ctx context.Context, protocol, username string) error
	SetStatus(ctx context.Context, protocol, username, status string) error
	List(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error)
	CountByProtocol(ctx context.Context, protocol string) (int, error)
}

// accountRepository implements AccountRepository.
type accountRepository struct {
	db *sql.DB
}

// NewAccountRepository creates a new AccountRepository.
func NewAccountRepository(db *sql.DB) AccountRepository {
	return &accountRepository{db: db}
}

// GetByUsername retrieves an account by protocol and username.
func (r *accountRepository) GetByUsername(ctx context.Context, protocol, username string) (*model.Account, error) {
	query := `
		SELECT id, protocol, username, secret, quota_bytes, used_bytes, 
			   limit_ip, expired_at, status, created_at, updated_at, note
		FROM accounts
		WHERE protocol = ? AND username = ? AND status != 'deleted'
		LIMIT 1
	`

	return r.queryAccount(ctx, query, protocol, username)
}

// GetByUsernameIncludingDeleted retrieves an account by protocol and username, including deleted accounts.
func (r *accountRepository) GetByUsernameIncludingDeleted(ctx context.Context, protocol, username string) (*model.Account, error) {
	query := `
		SELECT id, protocol, username, secret, quota_bytes, used_bytes, 
			   limit_ip, expired_at, status, created_at, updated_at, note
		FROM accounts
		WHERE protocol = ? AND username = ?
		LIMIT 1
	`

	return r.queryAccount(ctx, query, protocol, username)
}

// queryAccount is a helper to query a single account.
func (r *accountRepository) queryAccount(ctx context.Context, query string, args ...interface{}) (*model.Account, error) {
	var account model.Account
	var expiredAt, createdAt, updatedAt int64

	err := r.db.QueryRowContext(ctx, query, args...).Scan(
		&account.ID, &account.Protocol, &account.Username, &account.Secret,
		&account.QuotaBytes, &account.UsedBytes, &account.LimitIP,
		&expiredAt, &account.Status, &createdAt, &updatedAt, &account.Note,
	)

	if err == sql.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("query account: %w", err)
	}

	account.ExpiredAt = time.Unix(expiredAt, 0)
	account.CreatedAt = time.Unix(createdAt, 0)
	account.UpdatedAt = time.Unix(updatedAt, 0)

	return &account, nil
}

// Exists checks if an account exists.
func (r *accountRepository) Exists(ctx context.Context, protocol, username string) (bool, error) {
	query := `SELECT COUNT(*) FROM accounts WHERE protocol = ? AND username = ? AND status != 'deleted'`

	var count int
	err := r.db.QueryRowContext(ctx, query, protocol, username).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("check existence: %w", err)
	}

	return count > 0, nil
}

// SecretInUse checks if a secret is already used.
func (r *accountRepository) SecretInUse(ctx context.Context, secret string) (bool, error) {
	query := `SELECT COUNT(*) FROM accounts WHERE secret = ? AND status != 'deleted'`

	var count int
	err := r.db.QueryRowContext(ctx, query, secret).Scan(&count)
	if err != nil {
		return false, fmt.Errorf("check secret: %w", err)
	}

	return count > 0, nil
}

// Create inserts a new account.
func (r *accountRepository) Create(ctx context.Context, account *model.Account) error {
	query := `
		INSERT INTO accounts (protocol, username, secret, quota_bytes, limit_ip, expired_at, status)
		VALUES (?, ?, ?, ?, ?, ?, ?)
	`

	_, err := r.db.ExecContext(ctx, query,
		account.Protocol, account.Username, account.Secret,
		account.QuotaBytes, account.LimitIP,
		account.ExpiredAt.Unix(), account.Status,
	)
	if err != nil {
		return fmt.Errorf("insert account: %w", err)
	}

	return nil
}

// Update updates an existing account.
func (r *accountRepository) Update(ctx context.Context, account *model.Account) error {
	query := `
		UPDATE accounts 
		SET quota_bytes = ?, used_bytes = ?, limit_ip = ?, 
			expired_at = ?, status = ?, updated_at = strftime('%s','now'), note = ?
		WHERE protocol = ? AND username = ?
	`

	_, err := r.db.ExecContext(ctx, query,
		account.QuotaBytes, account.UsedBytes, account.LimitIP,
		account.ExpiredAt.Unix(), account.Status, account.Note,
		account.Protocol, account.Username,
	)
	if err != nil {
		return fmt.Errorf("update account: %w", err)
	}

	return nil
}

// Delete soft-deletes an account.
func (r *accountRepository) Delete(ctx context.Context, protocol, username string) error {
	return r.SetStatus(ctx, protocol, username, "deleted")
}

// SetStatus sets the status of an account.
func (r *accountRepository) SetStatus(ctx context.Context, protocol, username, status string) error {
	query := `
		UPDATE accounts 
		SET status = ?, updated_at = strftime('%s','now')
		WHERE protocol = ? AND username = ?
	`

	result, err := r.db.ExecContext(ctx, query, status, protocol, username)
	if err != nil {
		return fmt.Errorf("set status: %w", err)
	}

	rows, _ := result.RowsAffected()
	if rows == 0 {
		return model.ErrAccountNotFound
	}

	return nil
}

// List returns a paginated list of accounts.
func (r *accountRepository) List(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error) {
	// Count total
	countQuery := `SELECT COUNT(*) FROM accounts WHERE protocol = ? AND status != 'deleted'`
	var total int
	if err := r.db.QueryRowContext(ctx, countQuery, protocol).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count accounts: %w", err)
	}

	// Get page
	offset := (page - 1) * perPage
	query := `
		SELECT id, protocol, username, secret, quota_bytes, used_bytes, 
			   limit_ip, expired_at, status, created_at, updated_at, note
		FROM accounts
		WHERE protocol = ? AND status != 'deleted'
		ORDER BY username
		LIMIT ? OFFSET ?
	`

	rows, err := r.db.QueryContext(ctx, query, protocol, perPage, offset)
	if err != nil {
		return nil, 0, fmt.Errorf("list accounts: %w", err)
	}
	defer rows.Close()

	var accounts []*model.Account
	for rows.Next() {
		var account model.Account
		var expiredAt, createdAt, updatedAt int64

		if err := rows.Scan(
			&account.ID, &account.Protocol, &account.Username, &account.Secret,
			&account.QuotaBytes, &account.UsedBytes, &account.LimitIP,
			&expiredAt, &account.Status, &createdAt, &updatedAt, &account.Note,
		); err != nil {
			return nil, 0, fmt.Errorf("scan account: %w", err)
		}

		account.ExpiredAt = time.Unix(expiredAt, 0)
		account.CreatedAt = time.Unix(createdAt, 0)
		account.UpdatedAt = time.Unix(updatedAt, 0)

		accounts = append(accounts, &account)
	}

	return accounts, total, nil
}

// CountByProtocol returns the count of active accounts for a protocol.
func (r *accountRepository) CountByProtocol(ctx context.Context, protocol string) (int, error) {
	query := `SELECT COUNT(*) FROM accounts WHERE protocol = ? AND status = 'active'`
	var count int
	if err := r.db.QueryRowContext(ctx, query, protocol).Scan(&count); err != nil {
		return 0, fmt.Errorf("count by protocol: %w", err)
	}
	return count, nil
}
