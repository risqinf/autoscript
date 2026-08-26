package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/rs/zerolog"
)

// AccountService defines the interface for account operations.
type AccountService interface {
	GetAccount(ctx context.Context, protocol, username string) (*model.Account, error)
	CreateAccount(ctx context.Context, protocol string, req *model.CreateAccountRequest) (*model.Account, error)
	DeleteAccount(ctx context.Context, protocol, username string) error
	RenewAccount(ctx context.Context, protocol, username string, days int) (*model.Account, error)
	RecoverAccount(ctx context.Context, protocol, username string) error
	UpdateAccount(ctx context.Context, protocol, username string, req *model.CreateAccountRequest) (*model.Account, error)
	ListAccounts(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error)
}

// accountService implements AccountService.
type accountService struct {
	repo    repository.AccountRepository
	apiRepo repository.APIRepository
	config  *config.Config
	logger  *zerolog.Logger
}

// NewAccountService creates a new AccountService.
func NewAccountService(
	repo repository.AccountRepository,
	apiRepo repository.APIRepository,
	cfg *config.Config,
	logger *zerolog.Logger,
) AccountService {
	return &accountService{
		repo:    repo,
		apiRepo: apiRepo,
		config:  cfg,
		logger:  logger,
	}
}

// getLiveSSHUsage fetches real-time traffic statistics from ssh-ws API (port 8081).
func (s *accountService) getLiveSSHUsage(ctx context.Context, username string) int64 {
	client := &http.Client{Timeout: 800 * time.Millisecond}
	req, err := http.NewRequestWithContext(ctx, "GET", "http://127.0.0.1:8081/api/users", nil)
	if err != nil {
		return 0
	}
	resp, err := client.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()

	var result struct {
		Success bool `json:"success"`
		Data    struct {
			Count int `json:"count"`
			Users []struct {
				Username   string `json:"username"`
				TotalBytes int64  `json:"total_bytes"`
			} `json:"users"`
		} `json:"data"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return 0
	}
	for _, u := range result.Data.Users {
		if strings.EqualFold(u.Username, username) {
			return u.TotalBytes
		}
	}
	return 0
}

// GetAccount retrieves an account by protocol and username.
func (s *accountService) GetAccount(ctx context.Context, protocol, username string) (*model.Account, error) {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, fmt.Errorf("get account %s/%s: %w", protocol, username, err)
	}
	if account == nil {
		return nil, model.ErrAccountNotFound
	}

	// For SSH, query real-time live usage from ssh-ws proxy
	if protocol == "ssh" {
		if liveBytes := s.getLiveSSHUsage(ctx, username); liveBytes > 0 {
			account.UsedBytes = liveBytes
		}
	}

	return account, nil
}

// CreateAccount creates a new account.
func (s *accountService) CreateAccount(ctx context.Context, protocol string, req *model.CreateAccountRequest) (*model.Account, error) {
	// Check if username exists
	exists, err := s.repo.Exists(ctx, protocol, req.Username)
	if err != nil {
		return nil, fmt.Errorf("check existence: %w", err)
	}
	if exists {
		return nil, model.ErrAccountExists
	}

	// Create account based on protocol
	var account *model.Account
	switch protocol {
	case "ssh":
		account, err = s.createSSHAccount(ctx, req)
	case "vless", "vmess", "trojan":
		account, err = s.createXrayAccount(ctx, protocol, req)
	default:
		return nil, model.ErrInvalidProtocol
	}

	if err != nil {
		return nil, fmt.Errorf("create account: %w", err)
	}

	s.logger.Info().
		Str("protocol", protocol).
		Str("username", req.Username).
		Msg("account created")

	return account, nil
}

// createSSHAccount creates an SSH system user and database record.
func (s *accountService) createSSHAccount(ctx context.Context, req *model.CreateAccountRequest) (*model.Account, error) {
	// Calculate expiry
	expiry := time.Now().AddDate(0, 0, req.Days)
	expiryStr := expiry.Format("2006-01-02")

	// Create system user
	cmd := exec.CommandContext(ctx, "useradd",
		"-e", expiryStr,
		"-M", "-N",
		"-s", "/usr/sbin/nologin",
		req.Username,
	)
	if output, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("useradd failed: %s: %w", string(output), err)
	}

	// Set password
	cmd = exec.CommandContext(ctx, "chpasswd")
	cmd.Stdin = strings.NewReader(fmt.Sprintf("%s:%s", req.Username, req.Password))
	if output, err := cmd.CombinedOutput(); err != nil {
		// Rollback: delete user
		_ = exec.CommandContext(ctx, "userdel", "--force", req.Username).Run()
		return nil, fmt.Errorf("chpasswd failed: %s: %w", string(output), err)
	}

	// Create database record
	account := &model.Account{
		Protocol:  "ssh",
		Username:  req.Username,
		Secret:    req.Password,
		LimitIP:   req.LimitIP,
		ExpiredAt: expiry,
		Status:    "active",
	}

	if err := s.repo.Create(ctx, account); err != nil {
		// Rollback: delete user
		_ = exec.CommandContext(ctx, "userdel", "--force", req.Username).Run()
		return nil, fmt.Errorf("create db record: %w", err)
	}

	return account, nil
}

// createXrayAccount creates an xray client and database record.
func (s *accountService) createXrayAccount(ctx context.Context, protocol string, req *model.CreateAccountRequest) (*model.Account, error) {
	// Generate UUID if not provided
	secret := req.Secret
	if secret == "" {
		var err error
		secret, err = generateUUID()
		if err != nil {
			return nil, fmt.Errorf("generate uuid: %w", err)
		}
	}

	// Check if secret is in use
	inUse, err := s.repo.SecretInUse(ctx, secret)
	if err != nil {
		return nil, fmt.Errorf("check secret: %w", err)
	}
	if inUse {
		return nil, model.ErrSecretInUse
	}

	// Calculate quota
	var quotaBytes int64
	if req.Quota > 0 {
		quotaBytes = int64(req.Quota) * 1073741824
	}

	// Calculate expiry
	expiry := time.Now().AddDate(0, 0, req.Days)

	// Add client to xray config
	if err := s.addXrayClient(ctx, protocol, req.Username, secret); err != nil {
		s.logger.Error().
			Err(err).
			Str("protocol", protocol).
			Str("username", req.Username).
			Msg("addXrayClient failed")
		return nil, fmt.Errorf("add xray client: %w", err)
	}

	// Create database record
	account := &model.Account{
		Protocol:   protocol,
		Username:   req.Username,
		Secret:     secret,
		QuotaBytes: quotaBytes,
		LimitIP:    req.LimitIP,
		ExpiredAt:  expiry,
		Status:     "active",
	}

	if err := s.repo.Create(ctx, account); err != nil {
		// Rollback: remove xray client
		_ = s.removeXrayClient(ctx, protocol, req.Username)
		return nil, fmt.Errorf("create db record: %w", err)
	}

	return account, nil
}

// DeleteAccount deletes an account.
func (s *accountService) DeleteAccount(ctx context.Context, protocol, username string) error {
	// Get account first
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return model.ErrAccountNotFound
	}

	// Remove from xray config if not SSH
	if protocol != "ssh" {
		if err := s.removeXrayClient(ctx, protocol, username); err != nil {
			s.logger.Warn().Err(err).Msg("failed to remove xray client during delete")
		}
	}

	// Soft delete
	if err := s.repo.Delete(ctx, protocol, username); err != nil {
		return fmt.Errorf("delete account: %w", err)
	}

	// Delete system user if SSH
	if protocol == "ssh" {
		cmd := exec.CommandContext(ctx, "userdel", "--force", username)
		if output, err := cmd.CombinedOutput(); err != nil {
			s.logger.Warn().Err(err).Str("output", string(output)).Msg("failed to delete system user")
		}
	}

	s.logger.Info().
		Str("protocol", protocol).
		Str("username", username).
		Msg("account deleted")

	return nil
}

// RenewAccount extends an account's expiry.
func (s *accountService) RenewAccount(ctx context.Context, protocol, username string, days int) (*model.Account, error) {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return nil, model.ErrAccountNotFound
	}

	// Calculate new expiry (extend from max of now or current expiry)
	now := time.Now()
	base := account.ExpiredAt
	if base.Before(now) {
		base = now
	}
	account.ExpiredAt = base.AddDate(0, 0, days)

	// Update system user expiry if SSH
	if protocol == "ssh" {
		expiryStr := account.ExpiredAt.Format("2006-01-02")
		cmd := exec.CommandContext(ctx, "chage", "-E", expiryStr, username)
		if output, err := cmd.CombinedOutput(); err != nil {
			s.logger.Warn().Err(err).Str("output", string(output)).Msg("failed to update system user expiry")
		}
	}

	if err := s.repo.Update(ctx, account); err != nil {
		return nil, fmt.Errorf("update account: %w", err)
	}

	s.logger.Info().
		Str("protocol", protocol).
		Str("username", username).
		Int("days", days).
		Time("new_expiry", account.ExpiredAt).
		Msg("account renewed")

	return account, nil
}

// RecoverAccount recovers a deleted or suspended account.
func (s *accountService) RecoverAccount(ctx context.Context, protocol, username string) error {
	// For recovery, we need to query without the status filter
	// Use a direct query that includes deleted accounts
	account, err := s.repo.GetByUsernameIncludingDeleted(ctx, protocol, username)
	if err != nil {
		return fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return model.ErrAccountNotFound
	}

	// Only recover deleted or suspended accounts
	if account.Status != "deleted" && account.Status != "suspended" {
		return fmt.Errorf("account is %s, cannot recover", account.Status)
	}

	// Re-add to xray config if not SSH
	if protocol != "ssh" {
		if err := s.addXrayClient(ctx, protocol, username, account.Secret); err != nil {
			return fmt.Errorf("re-add xray client: %w", err)
		}
	}

	// Set status to active
	if err := s.repo.SetStatus(ctx, protocol, username, "active"); err != nil {
		return fmt.Errorf("set status: %w", err)
	}

	s.logger.Info().
		Str("protocol", protocol).
		Str("username", username).
		Msg("account recovered")

	return nil
}

// UpdateAccount updates an existing account.
func (s *accountService) UpdateAccount(ctx context.Context, protocol, username string, req *model.CreateAccountRequest) (*model.Account, error) {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return nil, model.ErrAccountNotFound
	}

	// Update fields
	if req.Quota > 0 {
		account.QuotaBytes = int64(req.Quota) * 1073741824
	} else if req.Quota == 0 {
		account.QuotaBytes = 0
	}

	if req.LimitIP >= 0 {
		account.LimitIP = req.LimitIP
	}

	if req.Days > 0 {
		account.ExpiredAt = account.ExpiredAt.AddDate(0, 0, req.Days)
	}

	if err := s.repo.Update(ctx, account); err != nil {
		return nil, fmt.Errorf("update account: %w", err)
	}

	s.logger.Info().
		Str("protocol", protocol).
		Str("username", username).
		Msg("account updated")

	return account, nil
}

// ListAccounts returns a paginated list of accounts.
func (s *accountService) ListAccounts(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error) {
	return s.repo.List(ctx, protocol, page, perPage)
}

// sanitizeInput escapes special characters for safe use in shell commands.
func sanitizeInput(input string) string {
	// Remove or escape characters that could cause command injection
	replacer := strings.NewReplacer(
		"'", "",
		"\"", "",
		"\\", "",
		";", "",
		"&", "",
		"|", "",
		"$", "",
		"`", "",
		"(", "",
		")", "",
		"{", "",
		"}", "",
		"[", "",
		"]", "",
		"<", "",
		">", "",
		"!", "",
		"#", "",
		"\n", "",
		"\r", "",
		"\t", "",
	)
	return replacer.Replace(input)
}

// getXrayTag returns the xray inbound tag for a given protocol.
func getXrayTag(protocol string) string {
	switch protocol {
	case "vless":
		return "vless-ws"
	case "vmess":
		return "vmess-ws"
	case "trojan":
		return "trojan-ws"
	}
	return ""
}

// addXrayClient adds a client to the xray config.
func (s *accountService) addXrayClient(ctx context.Context, protocol, username, secret string) error {
	// Sanitize inputs to prevent command injection
	safeUsername := sanitizeInput(username)
	safeSecret := sanitizeInput(secret)
	tag := getXrayTag(protocol)
	if tag == "" {
		return model.ErrInvalidProtocol
	}

	// Build a jq filter that errors if the inbound tag is not found.
	// This prevents silent failures where jq succeeds but the client is never added.
	var clientJSON string
	switch protocol {
	case "vless":
		clientJSON = fmt.Sprintf(`{"id":"%s","email":"%s"}`, safeSecret, safeUsername)
	case "vmess":
		clientJSON = fmt.Sprintf(`{"id":"%s","alterId":0,"email":"%s"}`, safeSecret, safeUsername)
	case "trojan":
		clientJSON = fmt.Sprintf(`{"password":"%s","email":"%s"}`, safeSecret, safeUsername)
	}

	// jq filter: validate tag exists first, then add client
	filter := fmt.Sprintf(
		`if ([.inbounds[] | select(.tag=="%s")] | length) == 0 then error("inbound tag '%s' not found in xray config") else (.inbounds[] | select(.tag=="%s") | .settings.clients) += [%s] end`,
		tag, tag, tag, clientJSON,
	)

	// Apply jq filter directly on the config file
	cmd := exec.CommandContext(ctx, "jq", filter, s.config.XrayConfig)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("jq filter failed for tag '%s': %s: %w", tag, string(exitErr.Stderr), err)
		}
		return fmt.Errorf("jq filter failed for tag '%s': %w", tag, err)
	}

	// Write to temp file (must end in .json for xray to recognize format)
	tmpFile := strings.TrimSuffix(s.config.XrayConfig, ".json") + ".tmp.json"
	if err := os.WriteFile(tmpFile, output, 0644); err != nil {
		return fmt.Errorf("write temp file: %w", err)
	}

	// Validate with xray -test
	testCmd := exec.CommandContext(ctx, s.config.XrayBinary, "-test", "-config", tmpFile)
	if testOut, err := testCmd.CombinedOutput(); err != nil {
		os.Remove(tmpFile)
		return fmt.Errorf("xray -test failed: %s: %w", string(testOut), err)
	}

	// Replace config atomically
	if err := os.Rename(tmpFile, s.config.XrayConfig); err != nil {
		os.Remove(tmpFile)
		return fmt.Errorf("replace config: %w", err)
	}

	// Reload xray (SIGHUP if possible, else restart)
	reloadCmd := exec.CommandContext(ctx, "systemctl", "reload-or-restart", "xray")
	if reloadOut, err := reloadCmd.CombinedOutput(); err != nil {
		s.logger.Warn().Err(err).Str("output", string(reloadOut)).Msg("failed to reload xray")
	}

	s.logger.Info().
		Str("tag", tag).
		Str("username", safeUsername).
		Msg("xray client added")

	return nil
}

// removeXrayClient removes a client from the xray config.
func (s *accountService) removeXrayClient(ctx context.Context, protocol, username string) error {
	// Sanitize input
	safeUsername := sanitizeInput(username)
	tag := getXrayTag(protocol)
	if tag == "" {
		return model.ErrInvalidProtocol
	}

	// Use .email for vless/vmess and .password for trojan to match the client
	var filter string
	if protocol == "trojan" {
		filter = fmt.Sprintf(`(.inbounds[] | select(.tag=="%s") | .settings.clients) |= map(select(.email != "%s"))`, tag, safeUsername)
	} else {
		filter = fmt.Sprintf(`(.inbounds[] | select(.tag=="%s") | .settings.clients) |= map(select(.email != "%s"))`, tag, safeUsername)
	}

	// Apply jq filter directly on the config file
	cmd := exec.CommandContext(ctx, "jq", filter, s.config.XrayConfig)
	output, err := cmd.Output()
	if err != nil {
		// Non-fatal: log but don't block delete
		s.logger.Warn().Err(err).Str("tag", tag).Str("username", safeUsername).Msg("jq filter failed during remove")
		return nil
	}

	// Write to temp file (must end in .json for xray to recognize format)
	tmpFile := strings.TrimSuffix(s.config.XrayConfig, ".json") + ".tmp.json"
	if err := os.WriteFile(tmpFile, output, 0644); err != nil {
		return fmt.Errorf("write temp file: %w", err)
	}

	// Validate with xray -test
	testCmd := exec.CommandContext(ctx, s.config.XrayBinary, "-test", "-config", tmpFile)
	if testOut, err := testCmd.CombinedOutput(); err != nil {
		os.Remove(tmpFile)
		s.logger.Warn().Str("output", string(testOut)).Msg("xray -test failed on remove, skipping")
		return nil
	}

	// Replace config atomically
	if err := os.Rename(tmpFile, s.config.XrayConfig); err != nil {
		os.Remove(tmpFile)
		return fmt.Errorf("replace config: %w", err)
	}

	// Reload xray
	reloadCmd := exec.CommandContext(ctx, "systemctl", "reload-or-restart", "xray")
	if reloadOut, err := reloadCmd.CombinedOutput(); err != nil {
		s.logger.Warn().Err(err).Str("output", string(reloadOut)).Msg("failed to reload xray")
	}

	s.logger.Info().
		Str("tag", tag).
		Str("username", safeUsername).
		Msg("xray client removed")

	return nil
}

// generateUUID generates a random UUIDv4 using crypto/rand.
func generateUUID() (string, error) {
	uuid := make([]byte, 16)
	if _, err := rand.Read(uuid); err != nil {
		return "", fmt.Errorf("generate random bytes: %w", err)
	}

	// Set version (4) and variant (10xx)
	uuid[6] = (uuid[6] & 0x0f) | 0x40
	uuid[8] = (uuid[8] & 0x3f) | 0x80

	return fmt.Sprintf("%x-%x-%x-%x-%x",
		uuid[0:4], uuid[4:6], uuid[6:8], uuid[8:10], uuid[10:16]), nil
}

// generateRandomString generates a random hex string of the given length.
func generateRandomString(length int) (string, error) {
	bytes := make([]byte, (length+1)/2)
	if _, err := rand.Read(bytes); err != nil {
		return "", fmt.Errorf("generate random bytes: %w", err)
	}
	return hex.EncodeToString(bytes)[:length], nil
}
