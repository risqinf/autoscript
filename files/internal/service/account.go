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
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/risqinf/autoscript-api/internal/cache"
	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
)

// AccountService defines the interface for single and Flash-Sale bulk account operations.
type AccountService interface {
	GetAccount(ctx context.Context, protocol, username string) (*model.Account, error)
	CreateAccount(ctx context.Context, protocol string, req *model.CreateAccountRequest) (*model.Account, error)
	CreateBulkAccounts(ctx context.Context, protocol string, req *model.BulkCreateRequest) (*model.BulkCreateResult, error)
	DeleteAccount(ctx context.Context, protocol, username string) error
	DeleteBulkAccounts(ctx context.Context, protocol string, usernames []string) (int, error)
	DeleteUserAutoDetect(ctx context.Context, username string) ([]string, error)
	RenewAccount(ctx context.Context, protocol, username string, days int) (*model.Account, error)
	RenewAccountWithOptions(ctx context.Context, protocol, username string, days int, resetQuota bool) (*model.Account, error)
	RenewBulkAccounts(ctx context.Context, protocol string, usernames []string, days int) ([]*model.Account, error)
	RenewUserAutoDetect(ctx context.Context, username string, days int, resetQuota bool) ([]*model.Account, error)
	RecoverAccount(ctx context.Context, protocol, username string) error
	SuspendAccount(ctx context.Context, protocol, username, reason string) (*model.Account, error)
	UnsuspendAccount(ctx context.Context, protocol, username string) (*model.Account, error)
	ResetAccountQuota(ctx context.Context, protocol, username string) (*model.Account, error)
	KickAccount(ctx context.Context, protocol, username string) (int, error)
	CleanupAccounts(ctx context.Context) (int, error)
	UpdateAccount(ctx context.Context, protocol, username string, req *model.CreateAccountRequest) (*model.Account, error)
	ListAccounts(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error)
	ListAccountsFiltered(ctx context.Context, protocol, status, search string, page, perPage int) ([]*model.Account, int, error)
	GetAccountsSummary(ctx context.Context) ([]model.ProtocolSummary, error)
	GetAuditLogs(ctx context.Context, limit int) ([]model.AuditLogEntry, error)
}

// accountService implements AccountService.
type accountService struct {
	repo          repository.AccountRepository
	apiRepo       repository.APIRepository
	xraySvc       XrayService
	xrayMutator   *XrayConfigMutator
	shadowMutator *ShadowMutator
	noobzMu       sync.Mutex
	snap          *cache.SnapshotCache
	config        *config.Config
	logger        *zerolog.Logger
	httpClient    *http.Client
}

// NewAccountService creates a new AccountService (backward-compatible constructor).
func NewAccountService(
	repo repository.AccountRepository,
	apiRepo repository.APIRepository,
	cfg *config.Config,
	logger *zerolog.Logger,
) AccountService {
	return NewAccountServiceFull(repo, apiRepo, NewXrayService(cfg, logger), cache.NewSnapshotCache(), cfg, logger)
}

// NewAccountServiceFull creates an AccountService wired with XrayService and shared SnapshotCache.
func NewAccountServiceFull(
	repo repository.AccountRepository,
	apiRepo repository.APIRepository,
	xraySvc XrayService,
	snap *cache.SnapshotCache,
	cfg *config.Config,
	logger *zerolog.Logger,
) AccountService {
	if snap == nil {
		snap = cache.NewSnapshotCache()
	}
	if xraySvc == nil {
		xraySvc = NewXrayService(cfg, logger)
	}
	return &accountService{
		repo:          repo,
		apiRepo:       apiRepo,
		xraySvc:       xraySvc,
		xrayMutator:   NewXrayConfigMutator(cfg, logger),
		shadowMutator: NewShadowMutator(),
		snap:          snap,
		config:        cfg,
		logger:        logger,
		httpClient: &http.Client{
			Timeout: 800 * time.Millisecond,
		},
	}
}

func (s *accountService) invalidateCaches() {
	if s.snap != nil {
		s.snap.InvalidatePrefix("monitor:")
		s.snap.InvalidatePrefix("quota:")
	}
}

func skipSystemUserProvision() bool {
	return isTestMode()
}

// getLiveSSHUsage fetches real-time traffic statistics from ssh_proto_usage + ssh-ws API (:8081).
func (s *accountService) getLiveSSHUsage(ctx context.Context, username string) int64 {
	var best int64
	if bd, err := s.repo.GetSSHProtoUsage(ctx, username); err == nil && bd.Total > best {
		best = bd.Total
	}

	wsURL := "http://127.0.0.1:8081"
	if s.config != nil && s.config.SSHWSAPI != "" {
		wsURL = s.config.SSHWSAPI
	}
	req, err := http.NewRequestWithContext(ctx, "GET", wsURL+"/api/users", nil)
	if err != nil {
		return best
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		return best
	}
	defer resp.Body.Close()

	var result struct {
		Success bool `json:"success"`
		Data    struct {
			Users []struct {
				Username   string `json:"username"`
				TotalBytes int64  `json:"total_bytes"`
			} `json:"users"`
		} `json:"data"`
	}
	if json.NewDecoder(resp.Body).Decode(&result) == nil {
		for _, u := range result.Data.Users {
			if strings.EqualFold(u.Username, username) && u.TotalBytes > best {
				best = u.TotalBytes
				break
			}
		}
	}
	return best
}

var reXrayStatVal = regexp.MustCompile(`"value":\s*"?(\d+)"?`)

func (s *accountService) getLiveXrayUsage(ctx context.Context, username string) int64 {
	if s.config == nil || s.config.XrayBinary == "" {
		return 0
	}
	if _, err := os.Stat(s.config.XrayBinary); err != nil {
		return 0
	}
	var total int64
	for _, dir := range []string{"uplink", "downlink"} {
		statName := fmt.Sprintf("user>>>%s>>>traffic>>>%s", username, dir)
		cmd := exec.CommandContext(ctx, s.config.XrayBinary, "api", "stats", "--server="+s.config.XrayAPIAddress, "-name", statName)
		output, err := cmd.Output()
		if err != nil {
			continue
		}
		if matches := reXrayStatVal.FindSubmatch(output); len(matches) > 1 {
			if val, err := strconv.ParseInt(string(matches[1]), 10, 64); err == nil && val > 0 {
				total += val
			}
		}
	}
	return total
}

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

// GetAccount retrieves an account by protocol and username with live traffic counters.
func (s *accountService) GetAccount(ctx context.Context, protocol, username string) (*model.Account, error) {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, fmt.Errorf("get account %s/%s: %w", protocol, username, err)
	}
	if account == nil {
		return nil, model.ErrAccountNotFound
	}

	switch protocol {
	case "ssh":
		if liveBytes := s.getLiveSSHUsage(ctx, username); liveBytes > account.UsedBytes {
			account.UsedBytes = liveBytes
		}
	case "noobz":
		if liveBytes := s.getLiveNoobzUsage(username); liveBytes > account.UsedBytes {
			account.UsedBytes = liveBytes
		}
	case "vless", "vmess", "trojan":
		account.UsedBytes += s.getLiveXrayUsage(ctx, username)
	}

	return account, nil
}

func computeExpiry(days int, durationStr string) time.Time {
	now := time.Now()
	if durationStr != "" {
		if dur, ok := validator.ParseDuration(durationStr); ok && dur > 0 {
			return now.Add(dur)
		}
	}
	if days <= 0 {
		days = 1
	}
	return now.AddDate(0, 0, days)
}

// CreateAccount creates a single VPN account.
func (s *accountService) CreateAccount(ctx context.Context, protocol string, req *model.CreateAccountRequest) (*model.Account, error) {
	exists, err := s.repo.Exists(ctx, protocol, req.Username)
	if err != nil {
		return nil, fmt.Errorf("check existence: %w", err)
	}
	if exists {
		return nil, model.ErrAccountExists
	}

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
		return nil, err
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "create", protocol, account.Username, fmt.Sprintf("quota=%dB limit_ip=%d", account.QuotaBytes, account.LimitIP))
	s.invalidateCaches()
	return account, nil
}

// CreateBulkAccounts provisions up to 1,000 accounts in a single high-speed Flash-Sale batch!
// - Single SQLite existence check + single SQLite transaction (CreateBatch)
// - Single Xray JSON parse + mutation + reload (for vless/vmess/trojan)
// - Parallel useradd + single chpasswd pipe (for ssh)
func (s *accountService) CreateBulkAccounts(ctx context.Context, protocol string, req *model.BulkCreateRequest) (*model.BulkCreateResult, error) {
	start := time.Now()

	items := req.Accounts
	if len(items) == 0 {
		prefix := req.Prefix
		if prefix == "" {
			prefix = protocol + "_"
		}
		passLen := req.PasswordLength
		if passLen < 6 || passLen > 32 {
			passLen = 10
		}
		items = make([]model.CreateAccountRequest, req.Count)
		batchRand := randomHex(4)
		for i := 0; i < req.Count; i++ {
			uname := fmt.Sprintf("%s%s_%04d", prefix, batchRand, i+1)
			if len(uname) > 32 {
				uname = uname[:27] + fmt.Sprintf("_%04d", i+1)
			}
			pwd := req.Password
			if (protocol == "ssh" || protocol == "noobz") && pwd == "" {
				pwd = randomHex(passLen)
			}
			items[i] = model.CreateAccountRequest{
				Username: uname,
				Password: pwd,
				Quota:    req.Quota,
				LimitIP:  req.LimitIP,
				Days:     req.Days,
				Duration: req.Duration,
				Note:     req.Note,
			}
		}
	}

	atomicMode := true
	if req.Atomic != nil {
		atomicMode = *req.Atomic
	}
	includeCfg := true
	if req.IncludeConfig != nil {
		includeCfg = *req.IncludeConfig
	}

	usernames := make([]string, len(items))
	for i, it := range items {
		usernames[i] = it.Username
	}

	existingUsers, err := s.repo.ExistingUsernames(ctx, protocol, usernames)
	if err != nil {
		return nil, fmt.Errorf("batch check existing usernames: %w", err)
	}

	var candidateSecrets []string
	for i := range items {
		if protocol == "vless" || protocol == "vmess" {
			if items[i].Secret == "" {
				u, err := generateUUID()
				if err != nil {
					return nil, err
				}
				items[i].Secret = u
			}
			candidateSecrets = append(candidateSecrets, items[i].Secret)
		} else if protocol == "trojan" {
			if items[i].Secret == "" {
				items[i].Secret = randomHex(16)
			}
			candidateSecrets = append(candidateSecrets, items[i].Secret)
		}
	}

	existingSecrets, err := s.repo.SecretsInUse(ctx, candidateSecrets)
	if err != nil {
		return nil, fmt.Errorf("batch check secrets: %w", err)
	}

	var validItems []model.CreateAccountRequest
	var itemErrors []model.BulkItemError

	for i, it := range items {
		if existingUsers[it.Username] {
			if atomicMode {
				return nil, fmt.Errorf("%w: %s", model.ErrAccountExists, it.Username)
			}
			itemErrors = append(itemErrors, model.BulkItemError{
				Index:    i,
				Username: it.Username,
				Reason:   "account already exists",
			})
			continue
		}
		if (protocol == "vless" || protocol == "vmess" || protocol == "trojan") && existingSecrets[it.Secret] {
			if atomicMode {
				return nil, fmt.Errorf("%w: %s", model.ErrSecretInUse, it.Username)
			}
			itemErrors = append(itemErrors, model.BulkItemError{
				Index:    i,
				Username: it.Username,
				Reason:   "secret already in use",
			})
			continue
		}
		validItems = append(validItems, it)
	}

	if len(validItems) == 0 {
		return &model.BulkCreateResult{
			Protocol:       protocol,
			RequestedCount: len(items),
			CreatedCount:   0,
			FailedCount:    len(itemErrors),
			DurationMs:     time.Since(start).Milliseconds(),
			Accounts:       []model.BulkAccountOutput{},
			Errors:         itemErrors,
		}, nil
	}

	toPersist := make([]*model.Account, 0, len(validItems))

	switch protocol {
	case "vless", "vmess", "trojan":
		specs := make([]XrayClientSpec, len(validItems))
		for i, it := range validItems {
			specs[i] = XrayClientSpec{
				Username: it.Username,
				Secret:   it.Secret,
			}
			var qBytes int64
			if it.Quota > 0 {
				qBytes = int64(it.Quota) * 1073741824
			}
			toPersist = append(toPersist, &model.Account{
				Protocol:   protocol,
				Username:   it.Username,
				Secret:     it.Secret,
				QuotaBytes: qBytes,
				LimitIP:    it.LimitIP,
				ExpiredAt:  computeExpiry(it.Days, it.Duration),
				Status:     "active",
				Note:       it.Note,
			})
		}

		// Single-pass Xray JSON update + single reload for all 1..1,000 clients!
		if err := s.xrayMutator.AddClientsBatch(ctx, protocol, specs); err != nil {
			return nil, fmt.Errorf("xray batch provision: %w", err)
		}

		if err := s.repo.CreateBatch(ctx, toPersist); err != nil {
			// Rollback Xray batch
			rollbackNames := make([]string, len(specs))
			for i, sp := range specs {
				rollbackNames[i] = sp.Username
			}
			_ = s.xrayMutator.RemoveClientsBatch(ctx, protocol, rollbackNames)
			return nil, fmt.Errorf("db batch commit: %w", err)
		}

	case "ssh":
		provisionedUsers, provErrs := s.provisionSSHUsersBatch(ctx, validItems)
		itemErrors = append(itemErrors, provErrs...)
		for _, it := range provisionedUsers {
			var qBytes int64
			if it.Quota > 0 {
				qBytes = int64(it.Quota) * 1073741824
			}
			toPersist = append(toPersist, &model.Account{
				Protocol:   "ssh",
				Username:   it.Username,
				Secret:     it.Password,
				QuotaBytes: qBytes,
				LimitIP:    it.LimitIP,
				ExpiredAt:  computeExpiry(it.Days, it.Duration),
				Status:     "active",
				Note:       it.Note,
			})
		}
		if len(toPersist) > 0 {
			if err := s.repo.CreateBatch(ctx, toPersist); err != nil {
				if !skipSystemUserProvision() {
					_ = s.shadowMutator.WithLock(func(_ string) error {
						for _, acc := range toPersist {
							_ = exec.CommandContext(ctx, "userdel", "--force", acc.Username).Run()
						}
						return nil
					})
				}
				return nil, fmt.Errorf("db batch commit: %w", err)
			}
		}

	case "noobz":
		s.provisionNoobzUsersBatch(ctx, validItems)
		for _, it := range validItems {
			var qBytes int64
			if it.Quota > 0 {
				qBytes = int64(it.Quota) * 1073741824
			}
			toPersist = append(toPersist, &model.Account{
				Protocol:   "noobz",
				Username:   it.Username,
				Secret:     it.Password,
				QuotaBytes: qBytes,
				LimitIP:    it.LimitIP,
				ExpiredAt:  computeExpiry(it.Days, it.Duration),
				Status:     "active",
				Note:       it.Note,
			})
		}
		if err := s.repo.CreateBatch(ctx, toPersist); err != nil {
			return nil, fmt.Errorf("db batch commit: %w", err)
		}

	default:
		return nil, model.ErrInvalidProtocol
	}

	domain := s.config.Domain()
	outputs := make([]model.BulkAccountOutput, len(toPersist))
	for i, acc := range toPersist {
		out := model.BulkAccountOutput{Account: acc}
		if includeCfg && s.xraySvc != nil {
			if link, err := s.xraySvc.GetConfigLink(ctx, protocol, acc.Username, acc.Secret, domain); err == nil {
				out.Config = link
			}
		}
		outputs[i] = out
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "bulk_create", protocol, fmt.Sprintf("batch(%d)", len(toPersist)),
		fmt.Sprintf("requested=%d created=%d duration_ms=%d", len(items), len(toPersist), time.Since(start).Milliseconds()))
	s.invalidateCaches()

	return &model.BulkCreateResult{
		Protocol:       protocol,
		RequestedCount: len(items),
		CreatedCount:   len(toPersist),
		FailedCount:    len(itemErrors),
		DurationMs:     time.Since(start).Milliseconds(),
		Accounts:       outputs,
		Errors:         itemErrors,
	}, nil
}

func (s *accountService) provisionSSHUsersBatch(ctx context.Context, items []model.CreateAccountRequest) ([]model.CreateAccountRequest, []model.BulkItemError) {
	if skipSystemUserProvision() {
		return items, nil
	}

	var created []model.CreateAccountRequest
	var errs []model.BulkItemError

	_ = s.shadowMutator.WithLock(func(nologin string) error {
		var chpasswdBuf strings.Builder
		for i, it := range items {
			exp := computeExpiry(it.Days, it.Duration)
			expStr := exp.Format("2006-01-02")
			if exec.CommandContext(ctx, "id", it.Username).Run() == nil {
				_ = exec.CommandContext(ctx, "usermod", "-s", nologin, "-e", expStr, "-U", it.Username).Run()
			} else {
				cmd := exec.CommandContext(ctx, "useradd", "-e", expStr, "-M", "-N", "-s", nologin, it.Username)
				if out, err := cmd.CombinedOutput(); err != nil {
					errs = append(errs, model.BulkItemError{
						Index:    i,
						Username: it.Username,
						Reason:   "useradd failed: " + strings.TrimSpace(string(out)),
					})
					continue
				}
			}
			created = append(created, it)
			chpasswdBuf.WriteString(it.Username)
			chpasswdBuf.WriteByte(':')
			chpasswdBuf.WriteString(it.Password)
			chpasswdBuf.WriteByte('\n')
		}

		if len(created) > 0 {
			if out, err := runChpasswdBulk(ctx, chpasswdBuf.String()); err != nil {
				for _, u := range created {
					_ = exec.CommandContext(ctx, "userdel", "--force", u.Username).Run()
				}
				created = nil
				errs = append(errs, model.BulkItemError{
					Index:  0,
					Reason: "batch chpasswd failed: " + strings.TrimSpace(string(out)),
				})
			}
		}
		return nil
	})

	return created, errs
}

func (s *accountService) provisionNoobzUsersBatch(ctx context.Context, items []model.CreateAccountRequest) {
	if _, err := exec.LookPath("noobzvpns"); err != nil {
		return
	}
	s.noobzMu.Lock()
	defer s.noobzMu.Unlock()

	for _, req := range items {
		days := req.Days
		if days <= 0 {
			days = 1
		}
		args := []string{"add", req.Username, "-p", req.Password, "-e", strconv.Itoa(days)}
		if req.Quota > 0 {
			args = append(args, "-b", strconv.Itoa(req.Quota))
		}
		if req.LimitIP > 0 {
			args = append(args, "-d", strconv.Itoa(req.LimitIP))
		}
		_ = exec.CommandContext(ctx, "noobzvpns", args...).Run()
	}
}

func (s *accountService) createSSHAccount(ctx context.Context, req *model.CreateAccountRequest) (*model.Account, error) {
	expiry := computeExpiry(req.Days, req.Duration)
	expiryStr := expiry.Format("2006-01-02")

	var quotaBytes int64
	if req.Quota > 0 {
		quotaBytes = int64(req.Quota) * 1073741824
	}

	account := &model.Account{
		Protocol:   "ssh",
		Username:   req.Username,
		Secret:     req.Password,
		QuotaBytes: quotaBytes,
		LimitIP:    req.LimitIP,
		ExpiredAt:  expiry,
		Status:     "active",
		Note:       req.Note,
	}

	// Reserve (protocol, username) atomically in SQLite WAL first so duplicate concurrent orders never collide on OS shadow
	if err := s.repo.Create(ctx, account); err != nil {
		return nil, err
	}

	if err := s.shadowMutator.CreateUser(ctx, req.Username, req.Password, expiryStr); err != nil {
		_ = s.repo.Delete(ctx, "ssh", req.Username)
		return nil, err
	}

	_ = s.repo.ResetQuota(ctx, "ssh", req.Username)
	return account, nil
}

func (s *accountService) createXrayAccount(ctx context.Context, protocol string, req *model.CreateAccountRequest) (*model.Account, error) {
	secret := req.Secret
	if secret == "" {
		if protocol == "trojan" {
			secret = randomHex(16)
		} else {
			var err error
			secret, err = generateUUID()
			if err != nil {
				return nil, fmt.Errorf("generate uuid: %w", err)
			}
		}
	}

	inUse, err := s.repo.SecretInUse(ctx, secret)
	if err != nil {
		return nil, fmt.Errorf("check secret: %w", err)
	}
	if inUse {
		return nil, model.ErrSecretInUse
	}

	var quotaBytes int64
	if req.Quota > 0 {
		quotaBytes = int64(req.Quota) * 1073741824
	}
	expiry := computeExpiry(req.Days, req.Duration)

	account := &model.Account{
		Protocol:   protocol,
		Username:   req.Username,
		Secret:     secret,
		QuotaBytes: quotaBytes,
		LimitIP:    req.LimitIP,
		ExpiredAt:  expiry,
		Status:     "active",
		Note:       req.Note,
	}

	// Reserve (protocol, username) atomically in SQLite WAL first so 100 simultaneous orders never clobber Xray config
	if err := s.repo.Create(ctx, account); err != nil {
		return nil, err
	}

	if err := s.xrayMutator.AddClientsBatch(ctx, protocol, []XrayClientSpec{{Username: req.Username, Secret: secret}}); err != nil {
		_ = s.repo.Delete(ctx, protocol, req.Username)
		return nil, fmt.Errorf("add xray client: %w", err)
	}

	return account, nil
}

func (s *accountService) createNoobzAccount(ctx context.Context, req *model.CreateAccountRequest) (*model.Account, error) {
	expiry := computeExpiry(req.Days, req.Duration)
	var quotaBytes int64
	if req.Quota > 0 {
		quotaBytes = int64(req.Quota) * 1073741824
	}

	account := &model.Account{
		Protocol:   "noobz",
		Username:   req.Username,
		Secret:     req.Password,
		QuotaBytes: quotaBytes,
		LimitIP:    req.LimitIP,
		ExpiredAt:  expiry,
		Status:     "active",
		Note:       req.Note,
	}
	if err := s.repo.Create(ctx, account); err != nil {
		return nil, err
	}

	if _, err := exec.LookPath("noobzvpns"); err == nil {
		s.noobzMu.Lock()
		days := req.Days
		if days <= 0 {
			days = 1
		}
		args := []string{"add", req.Username, "-p", req.Password, "-e", strconv.Itoa(days)}
		if req.Quota > 0 {
			args = append(args, "-b", strconv.Itoa(req.Quota))
		}
		if req.LimitIP > 0 {
			args = append(args, "-d", strconv.Itoa(req.LimitIP))
		}
		_ = exec.CommandContext(ctx, "noobzvpns", args...).Run()
		s.noobzMu.Unlock()
	}

	return account, nil
}

// DeleteAccount deletes an account and disconnects active sessions without dropping other users.
func (s *accountService) DeleteAccount(ctx context.Context, protocol, username string) error {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return model.ErrAccountNotFound
	}

	if protocol == "vless" || protocol == "vmess" || protocol == "trojan" {
		_ = s.xrayMutator.RemoveClientsBatch(ctx, protocol, []string{username})
	}

	if err := s.repo.Delete(ctx, protocol, username); err != nil {
		return fmt.Errorf("delete account: %w", err)
	}

	if protocol == "ssh" && !skipSystemUserProvision() {
		_, _ = s.killSSHUserProcesses(ctx, username)
		_ = s.shadowMutator.WithLock(func(_ string) error {
			_ = exec.CommandContext(ctx, "userdel", "--force", username).Run()
			return nil
		})
	} else if protocol == "noobz" {
		s.noobzMu.Lock()
		_ = exec.CommandContext(ctx, "noobzvpns", "remove", username).Run()
		s.noobzMu.Unlock()
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "delete", protocol, username, "deleted via API")
	s.invalidateCaches()
	return nil
}

// DeleteBulkAccounts deletes up to 1,000 accounts in 1 Xray JSON pass + 1 SQLite transaction.
func (s *accountService) DeleteBulkAccounts(ctx context.Context, protocol string, usernames []string) (int, error) {
	if len(usernames) == 0 {
		return 0, nil
	}
	if protocol == "vless" || protocol == "vmess" || protocol == "trojan" {
		_ = s.xrayMutator.RemoveClientsBatch(ctx, protocol, usernames)
	}

	deleted, err := s.repo.DeleteBatch(ctx, protocol, usernames)
	if err != nil {
		return deleted, err
	}

	if protocol == "ssh" && !skipSystemUserProvision() {
		for _, u := range usernames {
			_, _ = s.killSSHUserProcesses(ctx, u)
		}
		_ = s.shadowMutator.WithLock(func(_ string) error {
			for _, u := range usernames {
				_ = exec.CommandContext(ctx, "userdel", "--force", u).Run()
			}
			return nil
		})
	} else if protocol == "noobz" {
		s.noobzMu.Lock()
		for _, u := range usernames {
			_ = exec.CommandContext(ctx, "noobzvpns", "remove", u).Run()
		}
		s.noobzMu.Unlock()
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "bulk_delete", protocol, fmt.Sprintf("batch(%d)", deleted), "")
	s.invalidateCaches()
	return deleted, nil
}

// DeleteUserAutoDetect automatically detects which protocol(s) username belongs to and deletes them cleanly.
func (s *accountService) DeleteUserAutoDetect(ctx context.Context, username string) ([]string, error) {
	accounts, err := s.repo.GetByUsernameAllProtocols(ctx, username)
	if err != nil {
		return nil, err
	}
	if len(accounts) == 0 {
		return nil, model.ErrAccountNotFound
	}

	deletedProtocols := make([]string, 0, len(accounts))
	for _, acc := range accounts {
		if err := s.DeleteAccount(ctx, acc.Protocol, username); err != nil {
			return deletedProtocols, err
		}
		deletedProtocols = append(deletedProtocols, acc.Protocol)
	}
	return deletedProtocols, nil
}

// RenewAccount extends an account's expiry.
func (s *accountService) RenewAccount(ctx context.Context, protocol, username string, days int) (*model.Account, error) {
	return s.RenewAccountWithOptions(ctx, protocol, username, days, false)
}

// RenewAccountWithOptions extends expiry and optionally resets quota & reactivates suspended accounts.
func (s *accountService) RenewAccountWithOptions(ctx context.Context, protocol, username string, days int, resetQuota bool) (*model.Account, error) {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return nil, model.ErrAccountNotFound
	}

	wasInactive := account.Status != "active"
	now := time.Now()
	base := account.ExpiredAt
	if base.Before(now) {
		base = now
	}
	account.ExpiredAt = base.AddDate(0, 0, days)
	account.Status = "active"
	if resetQuota {
		account.UsedBytes = 0
		_ = s.repo.ResetQuota(ctx, protocol, username)
	}

	if protocol == "ssh" && !skipSystemUserProvision() {
		expiryStr := account.ExpiredAt.Format("2006-01-02")
		_ = s.shadowMutator.WithLock(func(nologin string) error {
			_ = exec.CommandContext(ctx, "usermod", "-s", nologin, "-e", expiryStr, "-U", username).Run()
			return nil
		})
	} else if protocol == "noobz" {
		s.noobzMu.Lock()
		_ = exec.CommandContext(ctx, "noobzvpns", "unblock", username).Run()
		_ = exec.CommandContext(ctx, "noobzvpns", "edit", username, "-e", strconv.Itoa(days)).Run()
		s.noobzMu.Unlock()
	} else if wasInactive && (protocol == "vless" || protocol == "vmess" || protocol == "trojan") {
		_ = s.xrayMutator.AddClientsBatch(ctx, protocol, []XrayClientSpec{{Username: username, Secret: account.Secret}})
	}

	if err := s.repo.Update(ctx, account); err != nil {
		return nil, fmt.Errorf("update account: %w", err)
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "renew", protocol, username, fmt.Sprintf("+%dd", days))
	s.invalidateCaches()
	return account, nil
}

// RenewBulkAccounts renews multiple accounts in a single SQLite transaction.
func (s *accountService) RenewBulkAccounts(ctx context.Context, protocol string, usernames []string, days int) ([]*model.Account, error) {
	updated, err := s.repo.RenewBatch(ctx, protocol, usernames, days)
	if err != nil {
		return nil, err
	}

	if protocol == "vless" || protocol == "vmess" || protocol == "trojan" {
		specs := make([]XrayClientSpec, len(updated))
		for i, acc := range updated {
			specs[i] = XrayClientSpec{Username: acc.Username, Secret: acc.Secret}
		}
		_ = s.xrayMutator.AddClientsBatch(ctx, protocol, specs)
	} else if protocol == "ssh" && !skipSystemUserProvision() {
		_ = s.shadowMutator.WithLock(func(nologin string) error {
			for _, acc := range updated {
				_ = exec.CommandContext(ctx, "usermod", "-s", nologin, "-e", acc.ExpiredAt.Format("2006-01-02"), "-U", acc.Username).Run()
			}
			return nil
		})
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "bulk_renew", protocol, fmt.Sprintf("batch(%d)", len(updated)), fmt.Sprintf("+%dd", days))
	s.invalidateCaches()
	return updated, nil
}

// RenewUserAutoDetect automatically detects which protocol(s) username belongs to and extends expiry.
func (s *accountService) RenewUserAutoDetect(ctx context.Context, username string, days int, resetQuota bool) ([]*model.Account, error) {
	accounts, err := s.repo.GetByUsernameAllProtocols(ctx, username)
	if err != nil {
		return nil, err
	}
	if len(accounts) == 0 {
		return nil, model.ErrAccountNotFound
	}

	renewed := make([]*model.Account, 0, len(accounts))
	for _, acc := range accounts {
		upd, err := s.RenewAccountWithOptions(ctx, acc.Protocol, username, days, resetQuota)
		if err != nil {
			return renewed, err
		}
		renewed = append(renewed, upd)
	}
	return renewed, nil
}

// SuspendAccount suspends an active account, removes/locks access, and disconnects its live sessions.
func (s *accountService) SuspendAccount(ctx context.Context, protocol, username, reason string) (*model.Account, error) {
	acc, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, err
	}
	if acc == nil {
		return nil, model.ErrAccountNotFound
	}

	if protocol == "vless" || protocol == "vmess" || protocol == "trojan" {
		_ = s.xrayMutator.RemoveClientsBatch(ctx, protocol, []string{username})
	} else if protocol == "ssh" && !skipSystemUserProvision() {
		_ = s.shadowMutator.WithLock(func(_ string) error {
			_ = exec.CommandContext(ctx, "usermod", "-L", "-e", "1", username).Run()
			return nil
		})
		_, _ = s.killSSHUserProcesses(ctx, username)
	} else if protocol == "noobz" {
		s.noobzMu.Lock()
		_ = exec.CommandContext(ctx, "noobzvpns", "block", username).Run()
		s.noobzMu.Unlock()
	}

	acc.Status = "suspended"
	if reason != "" {
		acc.Note = reason
	}
	if err := s.repo.Update(ctx, acc); err != nil {
		return nil, err
	}
	_ = s.repo.WriteAuditLog(ctx, "api", "suspend", protocol, username, reason)
	s.invalidateCaches()
	return acc, nil
}

// UnsuspendAccount restores a suspended account back to active status.
func (s *accountService) UnsuspendAccount(ctx context.Context, protocol, username string) (*model.Account, error) {
	if err := s.RecoverAccount(ctx, protocol, username); err != nil {
		return nil, err
	}
	return s.repo.GetByUsername(ctx, protocol, username)
}

// ResetAccountQuota resets used_bytes (and ssh_proto_usage) to 0 and reactivates if quota-suspended.
func (s *accountService) ResetAccountQuota(ctx context.Context, protocol, username string) (*model.Account, error) {
	if err := s.repo.ResetQuota(ctx, protocol, username); err != nil {
		return nil, err
	}
	acc, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil || acc == nil {
		return nil, model.ErrAccountNotFound
	}
	if acc.Status == "suspended" && !acc.IsExpired() {
		_ = s.RecoverAccount(ctx, protocol, username)
		acc, _ = s.repo.GetByUsername(ctx, protocol, username)
	}
	_ = s.repo.WriteAuditLog(ctx, "api", "reset_quota", protocol, username, "quota reset to 0")
	s.invalidateCaches()
	return acc, nil
}

// KickAccount disconnects active sessions of a single account without restarting global services.
func (s *accountService) KickAccount(ctx context.Context, protocol, username string) (int, error) {
	acc, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return 0, err
	}
	if acc == nil {
		return 0, model.ErrAccountNotFound
	}

	killed := 0
	if protocol == "ssh" && !skipSystemUserProvision() {
		killed, _ = s.killSSHUserProcesses(ctx, username)
	}
	_ = s.repo.WriteAuditLog(ctx, "api", "kick", protocol, username, fmt.Sprintf("terminated=%d", killed))
	s.invalidateCaches()
	return killed, nil
}

// CleanupAccounts marks expired accounts and purges old soft-deleted records.
func (s *accountService) CleanupAccounts(ctx context.Context) (int, error) {
	n, err := s.repo.CleanupExpiredAndDeleted(ctx)
	s.invalidateCaches()
	return n, err
}

// RecoverAccount recovers a deleted, expired, or suspended account without dropping other connected users.
func (s *accountService) RecoverAccount(ctx context.Context, protocol, username string) error {
	account, err := s.repo.GetByUsernameIncludingDeleted(ctx, protocol, username)
	if err != nil {
		return fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return model.ErrAccountNotFound
	}

	if account.ExpiredAt.Before(time.Now()) {
		account.ExpiredAt = time.Now().AddDate(0, 0, 1)
	}

	if protocol == "vless" || protocol == "vmess" || protocol == "trojan" {
		if err := s.xrayMutator.AddClientsBatch(ctx, protocol, []XrayClientSpec{{Username: username, Secret: account.Secret}}); err != nil {
			return fmt.Errorf("re-add xray client: %w", err)
		}
	} else if protocol == "ssh" && !skipSystemUserProvision() {
		expiryStr := account.ExpiredAt.Format("2006-01-02")
		if err := s.shadowMutator.WithLock(func(nologin string) error {
			if exec.CommandContext(ctx, "id", username).Run() != nil {
				userAddCmd := exec.CommandContext(ctx, "useradd", "-e", expiryStr, "-M", "-N", "-s", nologin, username)
				if output, err := userAddCmd.CombinedOutput(); err != nil {
					return fmt.Errorf("re-create system user: %s: %w", strings.TrimSpace(string(output)), err)
				}
				if output, err := runChpasswdBulk(ctx, fmt.Sprintf("%s:%s\n", username, account.Secret)); err != nil {
					return fmt.Errorf("set password for recovered user: %s: %w", strings.TrimSpace(string(output)), err)
				}
			} else {
				_ = exec.CommandContext(ctx, "usermod", "-U", "-s", nologin, "-e", expiryStr, username).Run()
			}
			return nil
		}); err != nil {
			return err
		}
	} else if protocol == "noobz" {
		s.noobzMu.Lock()
		if exec.CommandContext(ctx, "noobzvpns", "unblock", username).Run() != nil {
			days := int(time.Until(account.ExpiredAt).Hours() / 24)
			if days <= 0 {
				days = 30
			}
			args := []string{"add", username, "-p", account.Secret, "-e", strconv.Itoa(days)}
			if account.QuotaBytes > 0 {
				if qGB := account.QuotaBytes / 1073741824; qGB > 0 {
					args = append(args, "-b", strconv.FormatInt(qGB, 10))
				}
			}
			if account.LimitIP > 0 {
				args = append(args, "-d", strconv.Itoa(account.LimitIP))
			}
			_ = exec.CommandContext(ctx, "noobzvpns", args...).Run()
		}
		s.noobzMu.Unlock()
	}

	account.Status = "active"
	account.Note = ""
	if err := s.repo.Update(ctx, account); err != nil {
		return fmt.Errorf("update recovered account: %w", err)
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "recover", protocol, username, "account recovered")
	s.invalidateCaches()
	return nil
}

// UpdateAccount updates quota, IP limit, password/secret, or expiry on an existing account.
func (s *accountService) UpdateAccount(ctx context.Context, protocol, username string, req *model.CreateAccountRequest) (*model.Account, error) {
	account, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, fmt.Errorf("get account: %w", err)
	}
	if account == nil {
		return nil, model.ErrAccountNotFound
	}

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
	} else if req.Duration != "" {
		if dur, ok := validator.ParseDuration(req.Duration); ok {
			account.ExpiredAt = account.ExpiredAt.Add(dur)
		}
	}

	if req.Note != "" {
		account.Note = req.Note
	}

	if protocol == "ssh" && req.Password != "" {
		account.Secret = req.Password
		if !skipSystemUserProvision() {
			_ = s.shadowMutator.WithLock(func(_ string) error {
				_, _ = runChpasswdBulk(ctx, fmt.Sprintf("%s:%s\n", username, req.Password))
				return nil
			})
		}
	} else if protocol == "noobz" {
		args := []string{"edit", username}
		if req.Quota > 0 {
			args = append(args, "-b", strconv.Itoa(req.Quota))
		}
		if req.LimitIP > 0 {
			args = append(args, "-d", strconv.Itoa(req.LimitIP))
		}
		if req.Days > 0 {
			args = append(args, "-e", strconv.Itoa(req.Days))
		}
		if req.Password != "" {
			account.Secret = req.Password
			args = append(args, "-p", req.Password)
		}
		if len(args) > 2 {
			s.noobzMu.Lock()
			_ = exec.CommandContext(ctx, "noobzvpns", args...).Run()
			s.noobzMu.Unlock()
		}
	}

	if err := s.repo.Update(ctx, account); err != nil {
		return nil, fmt.Errorf("update account: %w", err)
	}

	_ = s.repo.WriteAuditLog(ctx, "api", "update", protocol, username, "")
	s.invalidateCaches()
	return account, nil
}

// ListAccounts returns a paginated list of accounts.
func (s *accountService) ListAccounts(ctx context.Context, protocol string, page, perPage int) ([]*model.Account, int, error) {
	return s.repo.List(ctx, protocol, page, perPage)
}

// ListAccountsFiltered returns a paginated list of accounts with optional status & username search.
func (s *accountService) ListAccountsFiltered(ctx context.Context, protocol, status, search string, page, perPage int) ([]*model.Account, int, error) {
	return s.repo.ListFiltered(ctx, protocol, status, search, page, perPage)
}

// GetAccountsSummary returns per-protocol account counts and traffic totals.
func (s *accountService) GetAccountsSummary(ctx context.Context) ([]model.ProtocolSummary, error) {
	return s.repo.SummaryByProtocol(ctx)
}

// GetAuditLogs returns the most recent administrative audit logs.
func (s *accountService) GetAuditLogs(ctx context.Context, limit int) ([]model.AuditLogEntry, error) {
	return s.repo.ListAuditLogs(ctx, limit)
}

// killSSHUserProcesses terminates only the target user's sshd/dropbear child processes without restarting dropbear.service.
func (s *accountService) killSSHUserProcesses(ctx context.Context, username string) (int, error) {
	killed := 0
	if exec.CommandContext(ctx, "pkill", "-KILL", "-u", username).Run() == nil {
		killed++
	}
	// Also target any root-owned Dropbear child PIDs authenticated as `username`
	pidMap := mapDropbearPIDToUser(map[string]bool{username: true})
	for pid, u := range pidMap {
		if u == username && pid > 1 {
			if p, err := os.FindProcess(pid); err == nil {
				_ = p.Kill()
				killed++
			}
		}
	}
	return killed, nil
}

func generateUUID() (string, error) {
	uuid := make([]byte, 16)
	if _, err := rand.Read(uuid); err != nil {
		return "", fmt.Errorf("generate random bytes: %w", err)
	}
	uuid[6] = (uuid[6] & 0x0f) | 0x40
	uuid[8] = (uuid[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x",
		uuid[0:4], uuid[4:6], uuid[6:8], uuid[8:10], uuid[10:16]), nil
}

func randomHex(length int) string {
	b := make([]byte, (length+1)/2)
	if _, err := rand.Read(b); err != nil {
		return "f0a1b2c3"
	}
	return hex.EncodeToString(b)[:length]
}
