package model

import "errors"

// Error types for API responses.
const (
	ErrValidation   = "VALIDATION_ERROR"
	ErrNotFound     = "NOT_FOUND"
	ErrConflict     = "CONFLICT"
	ErrUnauthorized = "UNAUTHORIZED"
	ErrForbidden    = "FORBIDDEN"
	ErrRateLimited  = "RATE_LIMITED"
	ErrInternal     = "INTERNAL_ERROR"
	ErrBadGateway   = "BAD_GATEWAY"
)

// Sentinel errors for business logic.
var (
	ErrAccountNotFound = errors.New("account not found")
	ErrAccountExists   = errors.New("account already exists")
	ErrSecretInUse     = errors.New("secret already in use")
	ErrQuotaExceeded   = errors.New("quota exceeded")
	ErrIPLimitExceeded = errors.New("IP limit exceeded")
	ErrInvalidProtocol = errors.New("invalid protocol")
	ErrXrayTestFailed  = errors.New("xray config test failed")
	ErrUserAddFailed   = errors.New("failed to create system user")
	ErrUserDelFailed   = errors.New("failed to delete system user")
)
