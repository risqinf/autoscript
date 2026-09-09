package service

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strconv"
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

// getLiveXrayUsage fetches real-time traffic (uplink + downlink) from Xray stats API (port 10085),
// mirroring 1:1 xray_user_bytes from scripts/lib/account.sh.
func (s *accountService) getLiveXrayUsage(ctx context.Context, username string) int64 {
	var total int64
	re := regexp.MustCompile(`"value":\s*"?(\d+)"?`)
	for _, dir := range []string{"uplink", "downlink"} {
		statName := fmt.Sprintf("user>>>%s>>>traffic>>>%s", username, dir)
		cmd := exec.CommandContext(ctx, s.config.XrayBinary, "api", "stats", "--server=127.0.0.1:10085", "-name", statName)
		output, err := cmd.Output()
		if err != nil {
			continue
		}
		matches := re.FindSubmatch(output)
		if len(matches) > 1 {
			if val, err := strconv.ParseInt(string(matches[1]), 10, 64); err == nil && val > 0 {
				total += val
			}
		}
	}
	return total
}

// getLiveNoobzUsage reads real-time traffic statistics from /etc/noobzvpns/db_user.json.
func (s *accountService) getLiveNoobzUsage(username string) int64 {
	data, err := os.ReadFile("/etc/noobzvpns/db_user.json")
	if err != nil {
		return 0
	}
	var dbUser struct {
		Users map[string]struct {
			Statistic struct {
				BytesUsage struct {
					Up   int64 `json:"up"`
					Down int64 `json:"down"`
				} `json:"bytes_usage"`
			} `json:"statistic"`
		} `json:"users"`
	}
	if err := json.Unmarshal(data, &dbUser); err != nil {
		return 0
	}
	if u, ok := dbUser.Users[username]; ok {
		return u.Statistic.BytesUsage.Up + u.Statistic.BytesUsage.Down
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
	switch protocol {
	case "ssh":
		if liveBytes := s.getLiveSSHUsage(ctx, username); liveBytes > 0 {
			account.UsedBytes = liveBytes
		}
	case "noobz":
		if liveBytes := s.getLiveNoobzUsage(username); liveBytes > 0 {
			account.UsedBytes = liveBytes
		}
	case "vless", "vmess", "trojan":
		// For Xray, live total = persisted DB bytes + un-reset counter (1:1 with cek-vmess/vless/trojan)
		liveBytes := s.getLiveXrayUsage(ctx, username)
		account.UsedBytes += liveBytes
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
	case "noobz":
		account, err = s.createNoobzAccount(ctx, req)
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

	// Calculate quota
	var quotaBytes int64
	if req.Quota > 0 {
		quotaBytes = int64(req.Quota) * 1073741824
	}

	// Create database record
	account := &model.Account{
		Protocol:   "ssh",
		Username:   req.Username,
		Secret:     req.Password,
		QuotaBytes: quotaBytes,
		LimitIP:    req.LimitIP,
		ExpiredAt:  expiry,
		Status:     "active",
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

// createNoobzAccount creates a NoobzVPN user and database record.
func (s *accountService) createNoobzAccount(ctx context.Context, req *model.CreateAccountRequest) (*model.Account, error) {
	expiry := time.Now().AddDate(0, 0, req.Days)
	expiryStr := expiry.Format("2006-01-02")

	// Call noobzvpns user add <username> <password>
	cmd := exec.CommandContext(ctx, "noobzvpns", "user", "add", req.Username, req.Password)
	if output, err := cmd.CombinedOutput(); err != nil {
		s.logger.Warn().Err(err).Str("output", string(output)).Msg("noobzvpns user add")
	}

	if req.Days > 0 {
		cmdExpire := exec.CommandContext(ctx, "noobzvpns", "user", "expire", req.Username, expiryStr)
		_ = cmdExpire.Run()
	}

	var quotaBytes int64
	if req.Quota > 0 {
		quotaBytes = int64(req.Quota) * 1073741824
		cmdBandwidth := exec.CommandContext(ctx, "noobzvpns", "user", "bandwidth", req.Username, fmt.Sprintf("%d", quotaBytes))
		_ = cmdBandwidth.Run()
	}

	if req.LimitIP > 0 {
		cmdDevices := exec.CommandContext(ctx, "noobzvpns", "user", "devices", req.Username, fmt.Sprintf("%d", req.LimitIP))
		_ = cmdDevices.Run()
	}

	account := &model.Account{
		Protocol:   "noobz",
		Username:   req.Username,
		Secret:     req.Password,
		QuotaBytes: quotaBytes,
		LimitIP:    req.LimitIP,
		ExpiredAt:  expiry,
		Status:     "active",
	}

	if err := s.repo.Create(ctx, account); err != nil {
		_ = exec.CommandContext(ctx, "noobzvpns", "user", "delete", req.Username).Run()
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

	// Remove from xray config if not SSH and not noobz
	if protocol != "ssh" && protocol != "noobz" {
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
	} else if protocol == "noobz" {
		cmd := exec.CommandContext(ctx, "noobzvpns", "user", "delete", username)
		if output, err := cmd.CombinedOutput(); err != nil {
			s.logger.Warn().Err(err).Str("output", string(output)).Msg("failed to delete noobz user")
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
	} else if protocol == "noobz" {
		expiryStr := account.ExpiredAt.Format("2006-01-02")
		cmd := exec.CommandContext(ctx, "noobzvpns", "user", "expire", username, expiryStr)
		if output, err := cmd.CombinedOutput(); err != nil {
			s.logger.Warn().Err(err).Str("output", string(output)).Msg("failed to update noobz expiry")
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

	// Re-add to xray config if not SSH and not noobz
	if protocol != "ssh" && protocol != "noobz" {
		if err := s.addXrayClient(ctx, protocol, username, account.Secret); err != nil {
			return fmt.Errorf("re-add xray client: %w", err)
		}
	} else if protocol == "noobz" {
		_ = exec.CommandContext(ctx, "noobzvpns", "user", "add", username, account.Secret).Run()
		expiryStr := account.ExpiredAt.Format("2006-01-02")
		_ = exec.CommandContext(ctx, "noobzvpns", "user", "expire", username, expiryStr).Run()
		if account.LimitIP > 0 {
			_ = exec.CommandContext(ctx, "noobzvpns", "user", "devices", username, fmt.Sprintf("%d", account.LimitIP)).Run()
		}
		if account.QuotaBytes > 0 {
			_ = exec.CommandContext(ctx, "noobzvpns", "user", "bandwidth", username, fmt.Sprintf("%d", account.QuotaBytes)).Run()
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

	if protocol == "noobz" {
		if req.Quota > 0 {
			_ = exec.CommandContext(ctx, "noobzvpns", "user", "bandwidth", username, fmt.Sprintf("%d", account.QuotaBytes)).Run()
		}
		if req.LimitIP >= 0 {
			_ = exec.CommandContext(ctx, "noobzvpns", "user", "devices", username, fmt.Sprintf("%d", account.LimitIP)).Run()
		}
		if req.Days > 0 {
			expiryStr := account.ExpiredAt.Format("2006-01-02")
			_ = exec.CommandContext(ctx, "noobzvpns", "user", "expire", username, expiryStr).Run()
		}
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

// addXrayClient adds a client to all matching inbounds in the xray config.
func (s *accountService) addXrayClient(ctx context.Context, protocol, username, secret string) error {
	// Sanitize inputs to prevent command injection
	safeUsername := sanitizeInput(username)
	safeSecret := sanitizeInput(secret)

	var clientJSON string
	switch protocol {
	case "vless":
		clientJSON = fmt.Sprintf(`{"id":"%s","email":"%s"}`, safeSecret, safeUsername)
	case "vmess":
		clientJSON = fmt.Sprintf(`{"id":"%s","alterId":0,"email":"%s"}`, safeSecret, safeUsername)
	case "trojan":
		clientJSON = fmt.Sprintf(`{"password":"%s","email":"%s"}`, safeSecret, safeUsername)
	default:
		return model.ErrInvalidProtocol
	}

	// jq filter: validate matching inbounds exist, then add client to all inbounds of that protocol
	filter := fmt.Sprintf(
		`if ([.inbounds[] | select(.protocol=="%s" and .settings.clients != null)] | length) == 0 then error("no inbounds for protocol '%s' found in xray config") else (.inbounds[] | select(.protocol=="%s" and .settings.clients != null) | .settings.clients) += [%s] end`,
		protocol, protocol, protocol, clientJSON,
	)

	// Apply jq filter directly on the config file
	cmd := exec.CommandContext(ctx, "jq", filter, s.config.XrayConfig)
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return fmt.Errorf("jq filter failed for protocol '%s': %s: %w", protocol, string(exitErr.Stderr), err)
		}
		return fmt.Errorf("jq filter failed for protocol '%s': %w", protocol, err)
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
		Str("protocol", protocol).
		Str("username", safeUsername).
		Msg("xray client added")

	return nil
}

// removeXrayClient removes a client from all matching inbounds in the xray config.
func (s *accountService) removeXrayClient(ctx context.Context, protocol, username string) error {
	// Sanitize input
	safeUsername := sanitizeInput(username)
	if protocol != "vless" && protocol != "vmess" && protocol != "trojan" {
		return model.ErrInvalidProtocol
	}

	filter := fmt.Sprintf(`(.inbounds[] | select(.protocol=="%s" and .settings.clients != null) | .settings.clients) |= map(select(.email != "%s"))`, protocol, safeUsername)

	// Apply jq filter directly on the config file
	cmd := exec.CommandContext(ctx, "jq", filter, s.config.XrayConfig)
	output, err := cmd.Output()
	if err != nil {
		// Non-fatal: log but don't block delete
		s.logger.Warn().Err(err).Str("protocol", protocol).Str("username", safeUsername).Msg("jq filter failed during remove")
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
		Str("protocol", protocol).
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
