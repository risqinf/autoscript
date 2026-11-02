package repository

import (
	"context"
	"database/sql"
	"fmt"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/model"
)

// AccountRepository defines the interface for account & quota database operations.
type AccountRepository interface {
	InitSchema() error

	GetByUsername(ctx context.Context, protocol, username string) (*model.Account, error)
	GetByUsernameIncludingDeleted(ctx context.Context, protocol, username string) (*model.Account, error)
	Exists(ctx context.Context, protocol, username string) (bool, error)
	SecretInUse(ctx context.Context, secret string) (bool, error)
	ExistingUsernames(ctx context.Context, protocol string, usernames []string) (map[string]bool, error)
	SecretsInUse(ctx context.Context, secrets []string) (map[string]bool, error)

	Create(ctx context.Context, account *model.Account) error
	CreateBatch(ctx context.Context, accounts []*model.Account) error
	Update(ctx context.Context, account *model.Account) error
	Delete(ctx context.Context, protocol, username string) error
	DeleteBatch(ctx context.Context, protocol string, usernames []string) (int, error)
	RenewBatch(ctx context.Context, protocol string, usernames []string, days int) ([]*model.Account, error)
	SetStatus(ctx context.Context, protocol, username, status string) error
	ResetQuota(ctx context.Context, protocol, username string) error
	CleanupExpiredAndDeleted(ctx context.Context) (int, error)

	List(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error)
	ListFiltered(ctx context.Context, protocol, status, search string, page, perPage int) ([]*model.Account, int, error)
	ListAllByProtocol(ctx context.Context, protocol string) ([]*model.Account, error)
	CountByProtocol(ctx context.Context, protocol string) (int, error)
	SummaryByProtocol(ctx context.Context) ([]model.ProtocolSummary, error)

	// SSH All-Protocol Quota Telemetry
	GetSSHProtoUsage(ctx context.Context, username string) (model.SSHProtoUsageBreakdown, error)
	GetAllSSHProtoUsage(ctx context.Context) (map[string]model.SSHProtoUsageBreakdown, model.SSHProtoUsageBreakdown, error)

	// Audit Logs
	WriteAuditLog(ctx context.Context, actor, action, protocol, username, detail string) error
	ListAuditLogs(ctx context.Context, limit int) ([]model.AuditLogEntry, error)
}

// accountRepository implements AccountRepository with separated read/write SQLite pools.
type accountRepository struct {
	readDB  *sql.DB
	writeDB *sql.DB
}

// NewAccountRepository creates an AccountRepository using a single *sql.DB handle.
func NewAccountRepository(db *sql.DB) AccountRepository {
	return &accountRepository{readDB: db, writeDB: db}
}

// NewAccountRepositoryWithPools creates an AccountRepository with dedicated WAL reader & writer pools.
func NewAccountRepositoryWithPools(readDB, writeDB *sql.DB) AccountRepository {
	if readDB == nil {
		readDB = writeDB
	}
	if writeDB == nil {
		writeDB = readDB
	}
	return &accountRepository{readDB: readDB, writeDB: writeDB}
}

// InitSchema ensures accounts, ssh_proto_usage, and audit_log tables exist with WAL mode enabled.
func (r *accountRepository) InitSchema() error {
	schema := `
	PRAGMA journal_mode=WAL;
	PRAGMA synchronous=NORMAL;
	PRAGMA temp_store=MEMORY;
	PRAGMA foreign_keys=ON;
	PRAGMA busy_timeout=10000;

	CREATE TABLE IF NOT EXISTS meta (
		key   TEXT PRIMARY KEY,
		value TEXT NOT NULL
	);

	CREATE TABLE IF NOT EXISTS accounts (
		id           INTEGER PRIMARY KEY AUTOINCREMENT,
		protocol     TEXT NOT NULL CHECK (protocol IN ('ssh','vless','vmess','trojan','noobz')),
		username     TEXT NOT NULL,
		secret       TEXT NOT NULL,
		quota_bytes  INTEGER NOT NULL DEFAULT 0,
		used_bytes   INTEGER NOT NULL DEFAULT 0,
		limit_ip     INTEGER NOT NULL DEFAULT 0,
		expired_at   INTEGER NOT NULL,
		status       TEXT NOT NULL DEFAULT 'active'
		               CHECK (status IN ('active','suspended','expired','deleted')),
		created_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		updated_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		note         TEXT NOT NULL DEFAULT '',
		UNIQUE (protocol, username)
	);

	CREATE INDEX IF NOT EXISTS idx_accounts_proto_status ON accounts(protocol,status);
	CREATE INDEX IF NOT EXISTS idx_accounts_expired ON accounts(expired_at);

	CREATE TABLE IF NOT EXISTS ssh_proto_usage (
		username     TEXT NOT NULL,
		sub_protocol TEXT NOT NULL CHECK (sub_protocol IN ('openssh','dropbear','ssh_ssl','ssh_ws','slowdns','openvpn')),
		rx_bytes     INTEGER NOT NULL DEFAULT 0,
		tx_bytes     INTEGER NOT NULL DEFAULT 0,
		updated_at   INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		PRIMARY KEY (username, sub_protocol)
	);

	CREATE INDEX IF NOT EXISTS idx_ssh_proto_user ON ssh_proto_usage(username);

	CREATE TABLE IF NOT EXISTS audit_log (
		id        INTEGER PRIMARY KEY AUTOINCREMENT,
		ts        INTEGER NOT NULL DEFAULT (strftime('%s','now')),
		actor     TEXT NOT NULL DEFAULT 'api',
		action    TEXT NOT NULL,
		protocol  TEXT,
		username  TEXT,
		detail    TEXT NOT NULL DEFAULT ''
	);

	INSERT OR IGNORE INTO meta(key,value) VALUES ('schema_version','2');
	`
	_, err := r.writeDB.Exec(schema)
	return err
}

// GetByUsername retrieves an active/suspended/expired account by protocol and username.
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

// GetByUsernameIncludingDeleted retrieves an account including soft-deleted rows.
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

func (r *accountRepository) queryAccount(ctx context.Context, query string, args ...interface{}) (*model.Account, error) {
	var account model.Account
	var expiredAt, createdAt, updatedAt int64

	err := r.readDB.QueryRowContext(ctx, query, args...).Scan(
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

// Exists checks if a non-deleted account exists.
func (r *accountRepository) Exists(ctx context.Context, protocol, username string) (bool, error) {
	query := `SELECT COUNT(*) FROM accounts WHERE protocol = ? AND username = ? AND status != 'deleted'`
	var count int
	if err := r.readDB.QueryRowContext(ctx, query, protocol, username).Scan(&count); err != nil {
		return false, fmt.Errorf("check existence: %w", err)
	}
	return count > 0, nil
}

// SecretInUse checks if a secret is already used by any non-deleted account.
func (r *accountRepository) SecretInUse(ctx context.Context, secret string) (bool, error) {
	query := `SELECT COUNT(*) FROM accounts WHERE secret = ? AND status != 'deleted'`
	var count int
	if err := r.readDB.QueryRowContext(ctx, query, secret).Scan(&count); err != nil {
		return false, fmt.Errorf("check secret: %w", err)
	}
	return count > 0, nil
}

// ExistingUsernames checks up to thousands of usernames in chunked IN-queries for Flash-Sale speed.
func (r *accountRepository) ExistingUsernames(ctx context.Context, protocol string, usernames []string) (map[string]bool, error) {
	existing := make(map[string]bool)
	if len(usernames) == 0 {
		return existing, nil
	}

	const chunkSize = 500
	for start := 0; start < len(usernames); start += chunkSize {
		end := start + chunkSize
		if end > len(usernames) {
			end = len(usernames)
		}
		chunk := usernames[start:end]

		placeholders := strings.Repeat("?,", len(chunk))
		placeholders = placeholders[:len(placeholders)-1]
		args := make([]interface{}, 0, len(chunk)+1)
		args = append(args, protocol)
		for _, u := range chunk {
			args = append(args, u)
		}

		query := fmt.Sprintf(`SELECT username FROM accounts WHERE protocol = ? AND status != 'deleted' AND username IN (%s)`, placeholders)
		rows, err := r.readDB.QueryContext(ctx, query, args...)
		if err != nil {
			return nil, fmt.Errorf("batch check usernames: %w", err)
		}
		for rows.Next() {
			var u string
			if err := rows.Scan(&u); err == nil {
				existing[u] = true
			}
		}
		rows.Close()
	}

	return existing, nil
}

// SecretsInUse checks multiple secrets in chunked IN-queries.
func (r *accountRepository) SecretsInUse(ctx context.Context, secrets []string) (map[string]bool, error) {
	used := make(map[string]bool)
	if len(secrets) == 0 {
		return used, nil
	}

	const chunkSize = 500
	for start := 0; start < len(secrets); start += chunkSize {
		end := start + chunkSize
		if end > len(secrets) {
			end = len(secrets)
		}
		chunk := secrets[start:end]

		placeholders := strings.Repeat("?,", len(chunk))
		placeholders = placeholders[:len(placeholders)-1]
		args := make([]interface{}, len(chunk))
		for i, s := range chunk {
			args[i] = s
		}

		query := fmt.Sprintf(`SELECT secret FROM accounts WHERE status != 'deleted' AND secret IN (%s)`, placeholders)
		rows, err := r.readDB.QueryContext(ctx, query, args...)
		if err != nil {
			return nil, fmt.Errorf("batch check secrets: %w", err)
		}
		for rows.Next() {
			var s string
			if err := rows.Scan(&s); err == nil {
				used[s] = true
			}
		}
		rows.Close()
	}

	return used, nil
}

// Create inserts or reactivates a single account.
func (r *accountRepository) Create(ctx context.Context, account *model.Account) error {
	now := time.Now().Unix()
	query := `
		INSERT INTO accounts (protocol, username, secret, quota_bytes, limit_ip, expired_at, status, created_at, updated_at, note)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(protocol, username) DO UPDATE SET
			secret = excluded.secret,
			quota_bytes = excluded.quota_bytes,
			used_bytes = 0,
			limit_ip = excluded.limit_ip,
			expired_at = excluded.expired_at,
			status = excluded.status,
			updated_at = excluded.updated_at,
			note = excluded.note
	`
	res, err := r.writeDB.ExecContext(ctx, query,
		account.Protocol, account.Username, account.Secret,
		account.QuotaBytes, account.LimitIP,
		account.ExpiredAt.Unix(), account.Status, now, now, account.Note,
	)
	if err != nil {
		return fmt.Errorf("insert account: %w", err)
	}
	if id, err := res.LastInsertId(); err == nil && id > 0 {
		account.ID = id
	}
	account.CreatedAt = time.Unix(now, 0)
	account.UpdatedAt = time.Unix(now, 0)
	return nil
}

// CreateBatch inserts hundreds of accounts inside a single atomic SQLite transaction.
func (r *accountRepository) CreateBatch(ctx context.Context, accounts []*model.Account) error {
	if len(accounts) == 0 {
		return nil
	}

	tx, err := r.writeDB.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin batch create tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO accounts (protocol, username, secret, quota_bytes, limit_ip, expired_at, status, created_at, updated_at, note)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(protocol, username) DO UPDATE SET
			secret = excluded.secret,
			quota_bytes = excluded.quota_bytes,
			used_bytes = 0,
			limit_ip = excluded.limit_ip,
			expired_at = excluded.expired_at,
			status = excluded.status,
			updated_at = excluded.updated_at,
			note = excluded.note
	`)
	if err != nil {
		return fmt.Errorf("prepare batch create: %w", err)
	}
	defer stmt.Close()

	now := time.Now().Unix()
	for _, acc := range accounts {
		res, err := stmt.ExecContext(ctx,
			acc.Protocol, acc.Username, acc.Secret,
			acc.QuotaBytes, acc.LimitIP,
			acc.ExpiredAt.Unix(), acc.Status, now, now, acc.Note,
		)
		if err != nil {
			return fmt.Errorf("insert batch account %s: %w", acc.Username, err)
		}
		if id, err := res.LastInsertId(); err == nil && id > 0 {
			acc.ID = id
		}
		acc.CreatedAt = time.Unix(now, 0)
		acc.UpdatedAt = time.Unix(now, 0)
	}

	if err := tx.Commit(); err != nil {
		return fmt.Errorf("commit batch create: %w", err)
	}
	return nil
}

// Update updates an existing account.
func (r *accountRepository) Update(ctx context.Context, account *model.Account) error {
	now := time.Now().Unix()
	query := `
		UPDATE accounts
		SET secret = ?, quota_bytes = ?, used_bytes = ?, limit_ip = ?,
			expired_at = ?, status = ?, updated_at = ?, note = ?
		WHERE protocol = ? AND username = ?
	`
	_, err := r.writeDB.ExecContext(ctx, query,
		account.Secret, account.QuotaBytes, account.UsedBytes, account.LimitIP,
		account.ExpiredAt.Unix(), account.Status, now, account.Note,
		account.Protocol, account.Username,
	)
	if err != nil {
		return fmt.Errorf("update account: %w", err)
	}
	account.UpdatedAt = time.Unix(now, 0)
	return nil
}

// Delete soft-deletes an account.
func (r *accountRepository) Delete(ctx context.Context, protocol, username string) error {
	return r.SetStatus(ctx, protocol, username, "deleted")
}

// DeleteBatch soft-deletes multiple accounts in a single transaction.
func (r *accountRepository) DeleteBatch(ctx context.Context, protocol string, usernames []string) (int, error) {
	if len(usernames) == 0 {
		return 0, nil
	}

	tx, err := r.writeDB.BeginTx(ctx, nil)
	if err != nil {
		return 0, fmt.Errorf("begin batch delete tx: %w", err)
	}
	defer func() { _ = tx.Rollback() }()

	stmt, err := tx.PrepareContext(ctx, `UPDATE accounts SET status = 'deleted', updated_at = ? WHERE protocol = ? AND username = ? AND status != 'deleted'`)
	if err != nil {
		return 0, err
	}
	defer stmt.Close()

	var sshStmt *sql.Stmt
	if protocol == "ssh" {
		sshStmt, _ = tx.PrepareContext(ctx, `DELETE FROM ssh_proto_usage WHERE username = ?`)
		if sshStmt != nil {
			defer sshStmt.Close()
		}
	}

	now := time.Now().Unix()
	affected := 0
	for _, u := range usernames {
		res, err := stmt.ExecContext(ctx, now, protocol, u)
		if err != nil {
			return affected, err
		}
		if rows, _ := res.RowsAffected(); rows > 0 {
			affected += int(rows)
		}
		if sshStmt != nil {
			_, _ = sshStmt.ExecContext(ctx, u)
		}
	}

	if err := tx.Commit(); err != nil {
		return 0, err
	}
	return affected, nil
}

// RenewBatch extends expiry for multiple accounts in a single transaction.
func (r *accountRepository) RenewBatch(ctx context.Context, protocol string, usernames []string, days int) ([]*model.Account, error) {
	if len(usernames) == 0 {
		return nil, nil
	}

	tx, err := r.writeDB.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() { _ = tx.Rollback() }()

	now := time.Now()
	nowUnix := now.Unix()
	var updated []*model.Account

	for _, u := range usernames {
		var acc model.Account
		var expUnix, cUnix, uUnix int64
		err := tx.QueryRowContext(ctx, `
			SELECT id, protocol, username, secret, quota_bytes, used_bytes,
				   limit_ip, expired_at, status, created_at, updated_at, note
			FROM accounts WHERE protocol = ? AND username = ? AND status != 'deleted' LIMIT 1
		`, protocol, u).Scan(
			&acc.ID, &acc.Protocol, &acc.Username, &acc.Secret,
			&acc.QuotaBytes, &acc.UsedBytes, &acc.LimitIP,
			&expUnix, &acc.Status, &cUnix, &uUnix, &acc.Note,
		)
		if err != nil {
			continue
		}
		base := time.Unix(expUnix, 0)
		if base.Before(now) {
			base = now
		}
		newExp := base.AddDate(0, 0, days)
		if _, err := tx.ExecContext(ctx, `UPDATE accounts SET expired_at = ?, status = 'active', updated_at = ? WHERE id = ?`,
			newExp.Unix(), nowUnix, acc.ID); err != nil {
			return nil, err
		}
		acc.ExpiredAt = newExp
		acc.Status = "active"
		acc.CreatedAt = time.Unix(cUnix, 0)
		acc.UpdatedAt = now
		updated = append(updated, &acc)
	}

	if err := tx.Commit(); err != nil {
		return nil, err
	}
	return updated, nil
}

// SetStatus sets the status of an account.
func (r *accountRepository) SetStatus(ctx context.Context, protocol, username, status string) error {
	query := `
		UPDATE accounts
		SET status = ?, updated_at = strftime('%s','now')
		WHERE protocol = ? AND username = ?
	`
	result, err := r.writeDB.ExecContext(ctx, query, status, protocol, username)
	if err != nil {
		return fmt.Errorf("set status: %w", err)
	}
	rows, _ := result.RowsAffected()
	if rows == 0 {
		return model.ErrAccountNotFound
	}
	return nil
}

// ResetQuota resets used_bytes (and ssh_proto_usage for SSH users) to 0.
func (r *accountRepository) ResetQuota(ctx context.Context, protocol, username string) error {
	res, err := r.writeDB.ExecContext(ctx,
		`UPDATE accounts SET used_bytes = 0, updated_at = strftime('%s','now') WHERE protocol = ? AND username = ? AND status != 'deleted'`,
		protocol, username,
	)
	if err != nil {
		return fmt.Errorf("reset quota: %w", err)
	}
	if rows, _ := res.RowsAffected(); rows == 0 {
		return model.ErrAccountNotFound
	}
	if protocol == "ssh" {
		_, _ = r.writeDB.ExecContext(ctx, `DELETE FROM ssh_proto_usage WHERE username = ?`, username)
	}
	return nil
}

// CleanupExpiredAndDeleted permanently purges soft-deleted rows and marks past-due active rows expired.
func (r *accountRepository) CleanupExpiredAndDeleted(ctx context.Context) (int, error) {
	now := time.Now().Unix()
	res1, err := r.writeDB.ExecContext(ctx, `UPDATE accounts SET status = 'expired', updated_at = ? WHERE status = 'active' AND expired_at <= ?`, now, now)
	if err != nil {
		return 0, err
	}
	c1, _ := res1.RowsAffected()

	res2, err := r.writeDB.ExecContext(ctx, `DELETE FROM accounts WHERE status = 'deleted' AND updated_at < ?`, now-86400*7)
	if err != nil {
		return int(c1), err
	}
	c2, _ := res2.RowsAffected()
	return int(c1 + c2), nil
}

// List returns a paginated list of non-deleted accounts for a protocol.
func (r *accountRepository) List(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error) {
	return r.ListFiltered(ctx, protocol, "", "", page, perPage)
}

// ListFiltered returns a paginated list of accounts with optional protocol, status, and username search filters.
func (r *accountRepository) ListFiltered(ctx context.Context, protocol, status, search string, page, perPage int) ([]*model.Account, int, error) {
	if page < 1 {
		page = 1
	}
	if perPage < 1 {
		perPage = 20
	}

	var conds []string
	var args []interface{}

	if protocol != "" && protocol != "all" {
		conds = append(conds, "protocol = ?")
		args = append(args, protocol)
	}
	if status != "" && status != "all" {
		conds = append(conds, "status = ?")
		args = append(args, status)
	} else {
		conds = append(conds, "status != 'deleted'")
	}
	if search != "" {
		conds = append(conds, "username LIKE ?")
		args = append(args, "%"+search+"%")
	}

	whereClause := strings.Join(conds, " AND ")

	var total int
	countSQL := "SELECT COUNT(*) FROM accounts WHERE " + whereClause
	if err := r.readDB.QueryRowContext(ctx, countSQL, args...).Scan(&total); err != nil {
		return nil, 0, fmt.Errorf("count accounts: %w", err)
	}

	offset := (page - 1) * perPage
	listArgs := make([]interface{}, len(args), len(args)+2)
	copy(listArgs, args)
	listArgs = append(listArgs, perPage, offset)

	query := `
		SELECT id, protocol, username, secret, quota_bytes, used_bytes,
			   limit_ip, expired_at, status, created_at, updated_at, note
		FROM accounts
		WHERE ` + whereClause + `
		ORDER BY protocol, username
		LIMIT ? OFFSET ?
	`

	rows, err := r.readDB.QueryContext(ctx, query, listArgs...)
	if err != nil {
		return nil, 0, fmt.Errorf("list accounts: %w", err)
	}
	defer rows.Close()

	accounts := make([]*model.Account, 0)
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

// ListAllByProtocol fetches all non-deleted accounts for a protocol (used by monitor & quota engines).
func (r *accountRepository) ListAllByProtocol(ctx context.Context, protocol string) ([]*model.Account, error) {
	rows, err := r.readDB.QueryContext(ctx, `
		SELECT id, protocol, username, secret, quota_bytes, used_bytes,
			   limit_ip, expired_at, status, created_at, updated_at, note
		FROM accounts
		WHERE protocol = ? AND status != 'deleted'
		ORDER BY username
	`, protocol)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	accounts := make([]*model.Account, 0)
	for rows.Next() {
		var account model.Account
		var expiredAt, createdAt, updatedAt int64
		if err := rows.Scan(
			&account.ID, &account.Protocol, &account.Username, &account.Secret,
			&account.QuotaBytes, &account.UsedBytes, &account.LimitIP,
			&expiredAt, &account.Status, &createdAt, &updatedAt, &account.Note,
		); err != nil {
			return nil, err
		}
		account.ExpiredAt = time.Unix(expiredAt, 0)
		account.CreatedAt = time.Unix(createdAt, 0)
		account.UpdatedAt = time.Unix(updatedAt, 0)
		accounts = append(accounts, &account)
	}
	return accounts, nil
}

// CountByProtocol returns the count of active accounts for a protocol.
func (r *accountRepository) CountByProtocol(ctx context.Context, protocol string) (int, error) {
	query := `SELECT COUNT(*) FROM accounts WHERE protocol = ? AND status = 'active'`
	var count int
	if err := r.readDB.QueryRowContext(ctx, query, protocol).Scan(&count); err != nil {
		return 0, fmt.Errorf("count by protocol: %w", err)
	}
	return count, nil
}

// SummaryByProtocol returns account counts and bandwidth totals grouped by protocol.
func (r *accountRepository) SummaryByProtocol(ctx context.Context) ([]model.ProtocolSummary, error) {
	protocols := []string{"ssh", "vless", "vmess", "trojan", "noobz"}
	byProto := make(map[string]*model.ProtocolSummary, len(protocols))
	for _, p := range protocols {
		byProto[p] = &model.ProtocolSummary{
			Protocol:       p,
			TotalUsedHuman: "0 B",
		}
	}

	rows, err := r.readDB.QueryContext(ctx, `
		SELECT protocol, status, COUNT(*), COALESCE(SUM(used_bytes), 0)
		FROM accounts
		WHERE status != 'deleted'
		GROUP BY protocol, status
	`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var proto, status string
		var cnt int
		var used int64
		if err := rows.Scan(&proto, &status, &cnt, &used); err != nil {
			continue
		}
		ps, ok := byProto[proto]
		if !ok {
			ps = &model.ProtocolSummary{Protocol: proto}
			byProto[proto] = ps
		}
		ps.Total += cnt
		ps.TotalUsedBytes += used
		switch status {
		case "active":
			ps.Active += cnt
		case "suspended":
			ps.Suspended += cnt
		case "expired":
			ps.Expired += cnt
		}
	}

	out := make([]model.ProtocolSummary, 0, len(protocols))
	for _, p := range protocols {
		ps := byProto[p]
		ps.TotalUsedHuman = FormatBytes(ps.TotalUsedBytes)
		out = append(out, *ps)
	}
	return out, nil
}

// GetSSHProtoUsage returns per-subprotocol SSH usage for a single username.
func (r *accountRepository) GetSSHProtoUsage(ctx context.Context, username string) (model.SSHProtoUsageBreakdown, error) {
	b := newEmptySSHBreakdown()
	rows, err := r.readDB.QueryContext(ctx, `
		SELECT sub_protocol, rx_bytes, tx_bytes, updated_at
		FROM ssh_proto_usage
		WHERE username = ?
	`, username)
	if err != nil {
		return b, err
	}
	defer rows.Close()

	for rows.Next() {
		var sp string
		var rx, tx, upd int64
		if err := rows.Scan(&sp, &rx, &tx, &upd); err != nil {
			continue
		}
		applySSHSubStat(&b, sp, rx, tx, upd)
	}
	finalizeSSHBreakdown(&b)
	return b, nil
}

// GetAllSSHProtoUsage returns per-user SSH sub-protocol breakdowns AND server-wide totals in 1 query.
func (r *accountRepository) GetAllSSHProtoUsage(ctx context.Context) (map[string]model.SSHProtoUsageBreakdown, model.SSHProtoUsageBreakdown, error) {
	byUser := make(map[string]model.SSHProtoUsageBreakdown)
	serverTotal := newEmptySSHBreakdown()

	rows, err := r.readDB.QueryContext(ctx, `
		SELECT username, sub_protocol, rx_bytes, tx_bytes, updated_at
		FROM ssh_proto_usage
	`)
	if err != nil {
		return byUser, serverTotal, err
	}
	defer rows.Close()

	for rows.Next() {
		var user, sp string
		var rx, tx, upd int64
		if err := rows.Scan(&user, &sp, &rx, &tx, &upd); err != nil {
			continue
		}
		ub, ok := byUser[user]
		if !ok {
			ub = newEmptySSHBreakdown()
		}
		applySSHSubStat(&ub, sp, rx, tx, upd)
		byUser[user] = ub

		applySSHSubStat(&serverTotal, sp, rx, tx, upd)
	}

	for u, ub := range byUser {
		finalizeSSHBreakdown(&ub)
		byUser[u] = ub
	}
	finalizeSSHBreakdown(&serverTotal)

	return byUser, serverTotal, nil
}

// WriteAuditLog records an administrative or bulk action in audit_log.
func (r *accountRepository) WriteAuditLog(ctx context.Context, actor, action, protocol, username, detail string) error {
	if actor == "" {
		actor = "api"
	}
	_, err := r.writeDB.ExecContext(ctx, `
		INSERT INTO audit_log (actor, action, protocol, username, detail)
		VALUES (?, ?, ?, ?, ?)
	`, actor, action, protocol, username, detail)
	return err
}

// ListAuditLogs returns the most recent audit_log entries.
func (r *accountRepository) ListAuditLogs(ctx context.Context, limit int) ([]model.AuditLogEntry, error) {
	if limit <= 0 || limit > 500 {
		limit = 100
	}
	rows, err := r.readDB.QueryContext(ctx, `
		SELECT id, ts, actor, action, COALESCE(protocol,''), COALESCE(username,''), detail
		FROM audit_log
		ORDER BY id DESC
		LIMIT ?
	`, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	entries := make([]model.AuditLogEntry, 0)
	for rows.Next() {
		var e model.AuditLogEntry
		var ts int64
		if err := rows.Scan(&e.ID, &ts, &e.Actor, &e.Action, &e.Protocol, &e.Username, &e.Detail); err == nil {
			e.Timestamp = time.Unix(ts, 0)
			entries = append(entries, e)
		}
	}
	return entries, nil
}

func newEmptySSHBreakdown() model.SSHProtoUsageBreakdown {
	return model.SSHProtoUsageBreakdown{
		OpenSSH:  model.SSHSubProtoStat{SubProtocol: "openssh", HumanTotal: "0 B"},
		Dropbear: model.SSHSubProtoStat{SubProtocol: "dropbear", HumanTotal: "0 B"},
		SSHSSL:   model.SSHSubProtoStat{SubProtocol: "ssh_ssl", HumanTotal: "0 B"},
		SSHWS:    model.SSHSubProtoStat{SubProtocol: "ssh_ws", HumanTotal: "0 B"},
		SlowDNS:  model.SSHSubProtoStat{SubProtocol: "slowdns", HumanTotal: "0 B"},
		OpenVPN:  model.SSHSubProtoStat{SubProtocol: "openvpn", HumanTotal: "0 B"},
		Human:    "0 B",
	}
}

func applySSHSubStat(b *model.SSHProtoUsageBreakdown, sp string, rx, tx, upd int64) {
	var target *model.SSHSubProtoStat
	switch sp {
	case "openssh":
		target = &b.OpenSSH
	case "dropbear":
		target = &b.Dropbear
	case "ssh_ssl":
		target = &b.SSHSSL
	case "ssh_ws":
		target = &b.SSHWS
	case "slowdns":
		target = &b.SlowDNS
	case "openvpn":
		target = &b.OpenVPN
	default:
		return
	}
	target.RXBytes += rx
	target.TXBytes += tx
	target.TotalBytes = target.RXBytes + target.TXBytes
	target.HumanTotal = FormatBytes(target.TotalBytes)
	if upd > target.UpdatedAt {
		target.UpdatedAt = upd
	}
	b.TotalRX += rx
	b.TotalTX += tx
}

func finalizeSSHBreakdown(b *model.SSHProtoUsageBreakdown) {
	b.Total = b.TotalRX + b.TotalTX
	b.Human = FormatBytes(b.Total)
}

// FormatBytes formats raw bytes into human-readable binary IEC units.
func FormatBytes(b int64) string {
	if b <= 0 {
		return "0 B"
	}
	const unit = 1024
	if b < unit {
		return fmt.Sprintf("%d B", b)
	}
	div, exp := int64(unit), 0
	for n := b / unit; n >= unit && exp < 4; n /= unit {
		div *= unit
		exp++
	}
	return fmt.Sprintf("%.2f %cB", float64(b)/float64(div), "KMGTPE"[exp])
}
