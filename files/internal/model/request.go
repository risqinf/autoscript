package model

// CreateAccountRequest represents a request to create or update an account.
type CreateAccountRequest struct {
	Username string `json:"username"`
	Password string `json:"password,omitempty"`
	Secret   string `json:"secret,omitempty"`
	Quota    int    `json:"quota"`    // GB (0 = unlimited)
	LimitIP  int    `json:"limit_ip"` // Max concurrent IPs (0 = unlimited)
	Days     int    `json:"days"`
	Duration string `json:"duration,omitempty"` // Optional: e.g. "30m", "2h", "30d"
	Note     string `json:"note,omitempty"`
}

// BulkCreateRequest supports Flash-Sale high-speed bulk provisioning of up to 1,000 accounts in 1 request
// directly on the standard POST /api/accounts/{protocol} endpoint.
// Supports EITHER:
//  1. Explicit list mode: provide `accounts` array of CreateAccountRequest (or a top-level JSON array)
//  2. Auto-generator mode: provide `count` (2..1000) + `prefix` (or `username` as prefix) + `days` + `quota` + `limit_ip`
type BulkCreateRequest struct {
	Protocol       string                 `json:"protocol,omitempty"`
	Accounts       []CreateAccountRequest `json:"accounts,omitempty"`
	Count          int                    `json:"count,omitempty"`
	Prefix         string                 `json:"prefix,omitempty"`
	Username       string                 `json:"username,omitempty"` // Compatibility alias: treated as Prefix when Count > 1
	PasswordLength int                    `json:"password_length,omitempty"`
	Password       string                 `json:"password,omitempty"` // Optional shared password for SSH/Noobz auto-gen
	Secret         string                 `json:"secret,omitempty"`   // Used when Count <= 1
	Quota          int                    `json:"quota"`              // Default GB when auto-generating or omitted
	LimitIP        int                    `json:"limit_ip"`           // Default IP limit when auto-generating or omitted
	Days           int                    `json:"days"`               // Default validity days when auto-generating or omitted
	Duration       string                 `json:"duration,omitempty"` // Optional duration override e.g. "1h", "7d"
	IncludeConfig  *bool                  `json:"include_config,omitempty"`
	Atomic         *bool                  `json:"atomic,omitempty"` // Default true: reject whole batch if any username conflicts
	Note           string                 `json:"note,omitempty"`
}

// BulkDeleteRequest deletes up to 1,000 accounts of a protocol in a single batch operation on DELETE /api/accounts/{protocol}.
type BulkDeleteRequest struct {
	Usernames []string `json:"usernames"`
}

// BulkRenewRequest renews up to 1,000 accounts of a protocol in a single batch operation on PUT /api/accounts/{protocol}.
type BulkRenewRequest struct {
	Usernames []string `json:"usernames"`
	Days      int      `json:"days"`
}

// RenewAccountRequest represents a request to renew an account.
type RenewAccountRequest struct {
	Days       int  `json:"days"`
	ResetQuota bool `json:"reset_quota,omitempty"`
}

// RecoveryAccountRequest represents a request to recover an account.
type RecoveryAccountRequest struct {
	Username string `json:"username"`
}

// DeleteAccountRequest represents a request to delete an account.
type DeleteAccountRequest struct {
	Username string `json:"username"`
}

// TrialRequest represents a request to create 1 or up to 1,000 trial accounts on POST /api/trials/{protocol}.
type TrialRequest struct {
	Count    int    `json:"count,omitempty"`
	Prefix   string `json:"prefix,omitempty"`
	Duration string `json:"duration"`
	Quota    int    `json:"quota,omitempty"`
	LimitIP  int    `json:"limit_ip"`
}

// TokenRequest represents a request to generate an API token.
type TokenRequest struct {
	Name string `json:"name"`
}

// TokenRevokeRequest represents a request to revoke an API token.
type TokenRevokeRequest struct {
	Token string `json:"token"`
}
