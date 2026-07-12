package validator

import (
	"regexp"
	"strings"

	"github.com/risqinf/autoscript-api/internal/model"
)

// Validator provides input validation methods.
type Validator struct {
	usernameRegex *regexp.Regexp
	uuidRegex     *regexp.Regexp
	durationRegex *regexp.Regexp
}

// New creates a new Validator.
func New() *Validator {
	return &Validator{
		usernameRegex: regexp.MustCompile(`^[a-zA-Z0-9_]{3,32}$`),
		uuidRegex:     regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`),
		durationRegex: regexp.MustCompile(`^[0-9]+[mhd]$`),
	}
}

// ValidateCreateAccount validates a create account request.
func (v *Validator) ValidateCreateAccount(protocol string, req *model.CreateAccountRequest) []model.ErrorDetail {
	var details []model.ErrorDetail

	// Username
	if !v.IsValidUsername(req.Username) {
		details = append(details, model.ErrorDetail{
			Field:   "username",
			Message: "must be 3-32 alphanumeric characters or underscore",
		})
	}

	// Protocol-specific validation
	switch protocol {
	case "ssh":
		if !v.IsValidPassword(req.Password) {
			details = append(details, model.ErrorDetail{
				Field:   "password",
				Message: "must not contain spaces, tabs, newlines, or colons",
			})
		}
		if req.Days < 1 || req.Days > 3650 {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
	case "vless", "vmess":
		if req.Secret != "" && !v.IsValidUUID(req.Secret) {
			details = append(details, model.ErrorDetail{
				Field:   "secret",
				Message: "must be a valid UUIDv4",
			})
		}
		if req.Days < 1 || req.Days > 3650 {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
	case "trojan":
		if req.Secret != "" && strings.ContainsAny(req.Secret, " \t\n\r:") {
			details = append(details, model.ErrorDetail{
				Field:   "secret",
				Message: "must not contain spaces, tabs, newlines, or colons",
			})
		}
		if req.Days < 1 || req.Days > 3650 {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
	default:
		details = append(details, model.ErrorDetail{
			Field:   "protocol",
			Message: "must be ssh, vless, vmess, or trojan",
		})
	}

	// Limit IP
	if req.LimitIP < 0 {
		details = append(details, model.ErrorDetail{
			Field:   "limit_ip",
			Message: "must be 0 or positive",
		})
	}

	// Quota
	if req.Quota < 0 {
		details = append(details, model.ErrorDetail{
			Field:   "quota",
			Message: "must be 0 or positive",
		})
	}

	return details
}

// ValidateRenew validates a renew request.
func (v *Validator) ValidateRenew(req *model.RenewAccountRequest) []model.ErrorDetail {
	var details []model.ErrorDetail

	if req.Days < 1 || req.Days > 3650 {
		details = append(details, model.ErrorDetail{
			Field:   "days",
			Message: "must be between 1 and 3650",
		})
	}

	return details
}

// ValidateTrial validates a trial request.
func (v *Validator) ValidateTrial(protocol string, req *model.TrialRequest) []model.ErrorDetail {
	var details []model.ErrorDetail

	if !v.IsValidDuration(req.Duration) {
		details = append(details, model.ErrorDetail{
			Field:   "duration",
			Message: "must be in format: 30m, 2h, or 1d",
		})
	}

	if req.LimitIP < 0 {
		details = append(details, model.ErrorDetail{
			Field:   "limit_ip",
			Message: "must be 0 or positive",
		})
	}

	return details
}

// IsValidUsername checks if a username is valid.
func (v *Validator) IsValidUsername(username string) bool {
	return v.usernameRegex.MatchString(username)
}

// IsValidUUID checks if a UUID is valid.
func (v *Validator) IsValidUUID(uuid string) bool {
	return v.uuidRegex.MatchString(uuid)
}

// IsValidPassword checks if a password is valid.
func (v *Validator) IsValidPassword(password string) bool {
	if password == "" {
		return false
	}
	return !strings.ContainsAny(password, " \t\n\r:")
}

// IsValidDuration checks if a duration string is valid.
func (v *Validator) IsValidDuration(duration string) bool {
	return v.durationRegex.MatchString(duration)
}

// IsValidProtocol checks if a protocol is valid.
func (v *Validator) IsValidProtocol(protocol string) bool {
	switch protocol {
	case "ssh", "vless", "vmess", "trojan":
		return true
	default:
		return false
	}
}
