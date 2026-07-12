package model

// CreateAccountRequest represents a request to create an account.
type CreateAccountRequest struct {
	Username string `json:"username"`
	Password string `json:"password,omitempty"`
	Secret   string `json:"secret,omitempty"`
	Quota    int    `json:"quota"`
	LimitIP  int    `json:"limit_ip"`
	Days     int    `json:"days"`
	Duration string `json:"duration,omitempty"`
}

// RenewAccountRequest represents a request to renew an account.
type RenewAccountRequest struct {
	Days int `json:"days"`
}

// RecoveryAccountRequest represents a request to recover an account.
type RecoveryAccountRequest struct {
	Username string `json:"username"`
}

// DeleteAccountRequest represents a request to delete an account.
type DeleteAccountRequest struct {
	Username string `json:"username"`
}

// TrialRequest represents a request to create a trial account.
type TrialRequest struct {
	Duration string `json:"duration"`
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
