package validator

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/model"
)

// Reserved Linux system usernames that must never be created, modified, or deleted as VPN SSH users.
var reservedSystemUsers = map[string]bool{
	"root": true, "bin": true, "daemon": true, "adm": true, "lp": true,
	"sync": true, "shutdown": true, "halt": true, "mail": true, "operator": true,
	"games": true, "ftp": true, "nobody": true, "dbus": true, "systemd": true,
	"sshd": true, "chrony": true, "nginx": true, "haproxy": true, "squid": true,
	"openvpn": true, "tss": true, "polkitd": true, "unbound": true, "dnsmasq": true,
	"dropbear": true, "xray": true, "vnstat": true, "rpc": true, "cockpit": true,
}

// AllowedManagedServices restricts service control endpoints to known VPN stack daemons.
var AllowedManagedServices = map[string]bool{
	"haproxy":                        true,
	"nginx":                          true,
	"xray":                           true,
	"dropbear":                       true,
	"ssh-ws":                         true,
	"sshd":                           true,
	"squid":                          true,
	"openvpn-server@server-tcp-1194": true,
	"slowdns":                        true,
	"noobzvpns":                      true,
	"vnstat":                         true,
	"firewalld":                      true,
	"loop-quota-ssh":                 true,
	"loop-limit-ssh":                 true,
	"loop-quota-xray":                true,
	"loop-limit-xray":                true,
	"dnsmasq-autoscript":             true,
}

// Validator provides strict, injection-proof input validation methods.
type Validator struct {
	usernameRegex *regexp.Regexp
	prefixRegex   *regexp.Regexp
	uuidRegex     *regexp.Regexp
	durationRegex *regexp.Regexp
	domainRegex   *regexp.Regexp
}

// New creates a new Validator.
func New() *Validator {
	return &Validator{
		usernameRegex: regexp.MustCompile(`^[a-zA-Z0-9_]{3,32}$`),
		prefixRegex:   regexp.MustCompile(`^[a-zA-Z0-9_]{1,16}$`),
		uuidRegex:     regexp.MustCompile(`^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$`),
		durationRegex: regexp.MustCompile(`^[0-9]{1,5}[mhd]$`),
		domainRegex:   regexp.MustCompile(`^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,251}[a-zA-Z0-9])?$`),
	}
}

// ValidateCreateAccount validates a create account request.
func (v *Validator) ValidateCreateAccount(protocol string, req *model.CreateAccountRequest) []model.ErrorDetail {
	var details []model.ErrorDetail

	if !v.IsValidUsername(req.Username) {
		details = append(details, model.ErrorDetail{
			Field:   "username",
			Message: "must be 3-32 alphanumeric characters or underscore and not a reserved system user",
		})
	}

	hasValidDuration := req.Duration != "" && v.IsValidDuration(req.Duration)
	if req.Duration != "" && !hasValidDuration {
		details = append(details, model.ErrorDetail{
			Field:   "duration",
			Message: "must be in format: 30m, 2h, or 30d",
		})
	}

	switch protocol {
	case "ssh", "noobz":
		if !v.IsValidPassword(req.Password) {
			details = append(details, model.ErrorDetail{
				Field:   "password",
				Message: "must be 1-64 printable characters without spaces, tabs, newlines, or colons",
			})
		}
		if !hasValidDuration && (req.Days < 1 || req.Days > 3650) {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
	case "vless", "vmess":
		if req.Secret != "" && !v.IsValidUUID(req.Secret) {
			details = append(details, model.ErrorDetail{
				Field:   "secret",
				Message: "must be a valid UUID",
			})
		}
		if !hasValidDuration && (req.Days < 1 || req.Days > 3650) {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
	case "trojan":
		if req.Secret != "" && !v.IsValidSecret(req.Secret) {
			details = append(details, model.ErrorDetail{
				Field:   "secret",
				Message: "must be 4-64 safe alphanumeric/symbol characters without quotes, spaces, or colons",
			})
		}
		if !hasValidDuration && (req.Days < 1 || req.Days > 3650) {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
	default:
		details = append(details, model.ErrorDetail{
			Field:   "protocol",
			Message: "must be ssh, vless, vmess, trojan, or noobz",
		})
	}

	if req.LimitIP < 0 || req.LimitIP > 1000 {
		details = append(details, model.ErrorDetail{
			Field:   "limit_ip",
			Message: "must be between 0 and 1000",
		})
	}

	if req.Quota < 0 || req.Quota > 1000000 {
		details = append(details, model.ErrorDetail{
			Field:   "quota",
			Message: "must be between 0 and 1000000 (GB)",
		})
	}

	return details
}

// ValidateBulkCreate validates a Flash-Sale bulk account creation request (up to maxBulk accounts).
func (v *Validator) ValidateBulkCreate(protocol string, req *model.BulkCreateRequest, maxBulk int) []model.ErrorDetail {
	var details []model.ErrorDetail

	if !v.IsValidProtocol(protocol) {
		details = append(details, model.ErrorDetail{
			Field:   "protocol",
			Message: "must be ssh, vless, vmess, trojan, or noobz",
		})
		return details
	}

	if maxBulk <= 0 {
		maxBulk = 1000
	}

	if len(req.Accounts) == 0 && req.Count <= 0 {
		details = append(details, model.ErrorDetail{
			Field:   "count",
			Message: fmt.Sprintf("provide either 'accounts' array or 'count' between 1 and %d", maxBulk),
		})
		return details
	}

	if len(req.Accounts) > maxBulk {
		details = append(details, model.ErrorDetail{
			Field:   "accounts",
			Message: fmt.Sprintf("cannot exceed %d accounts per single bulk request", maxBulk),
		})
		return details
	}

	if len(req.Accounts) == 0 {
		if req.Count < 1 || req.Count > maxBulk {
			details = append(details, model.ErrorDetail{
				Field:   "count",
				Message: fmt.Sprintf("must be between 1 and %d", maxBulk),
			})
		}
		if req.Prefix != "" && !v.prefixRegex.MatchString(req.Prefix) {
			details = append(details, model.ErrorDetail{
				Field:   "prefix",
				Message: "must be 1-16 alphanumeric characters or underscore",
			})
		}
		hasDur := req.Duration != "" && v.IsValidDuration(req.Duration)
		if req.Duration != "" && !hasDur {
			details = append(details, model.ErrorDetail{
				Field:   "duration",
				Message: "must be in format: 30m, 2h, or 30d",
			})
		}
		if !hasDur && (req.Days < 1 || req.Days > 3650) {
			details = append(details, model.ErrorDetail{
				Field:   "days",
				Message: "must be between 1 and 3650",
			})
		}
		if req.Password != "" && !v.IsValidPassword(req.Password) {
			details = append(details, model.ErrorDetail{
				Field:   "password",
				Message: "must not contain spaces, tabs, newlines, or colons",
			})
		}
		if req.LimitIP < 0 || req.LimitIP > 1000 {
			details = append(details, model.ErrorDetail{
				Field:   "limit_ip",
				Message: "must be between 0 and 1000",
			})
		}
		if req.Quota < 0 || req.Quota > 1000000 {
			details = append(details, model.ErrorDetail{
				Field:   "quota",
				Message: "must be between 0 and 1000000 (GB)",
			})
		}
		return details
	}

	seenUsers := make(map[string]bool, len(req.Accounts))
	seenSecrets := make(map[string]bool, len(req.Accounts))

	for i := range req.Accounts {
		item := &req.Accounts[i]
		if item.Days == 0 && req.Days > 0 {
			item.Days = req.Days
		}
		if item.Duration == "" && req.Duration != "" {
			item.Duration = req.Duration
		}
		if item.Quota == 0 && req.Quota > 0 {
			item.Quota = req.Quota
		}
		if item.LimitIP == 0 && req.LimitIP > 0 {
			item.LimitIP = req.LimitIP
		}
		if (protocol == "ssh" || protocol == "noobz") && item.Password == "" && req.Password != "" {
			item.Password = req.Password
		}

		itemErrs := v.ValidateCreateAccount(protocol, item)
		for _, ie := range itemErrs {
			details = append(details, model.ErrorDetail{
				Field:   fmt.Sprintf("accounts[%d].%s", i, ie.Field),
				Message: ie.Message,
			})
		}

		uKey := strings.ToLower(item.Username)
		if item.Username != "" {
			if seenUsers[uKey] {
				details = append(details, model.ErrorDetail{
					Field:   fmt.Sprintf("accounts[%d].username", i),
					Message: "duplicate username in bulk request",
				})
			}
			seenUsers[uKey] = true
		}

		if item.Secret != "" && (protocol == "vless" || protocol == "vmess" || protocol == "trojan") {
			if seenSecrets[item.Secret] {
				details = append(details, model.ErrorDetail{
					Field:   fmt.Sprintf("accounts[%d].secret", i),
					Message: "duplicate secret in bulk request",
				})
			}
			seenSecrets[item.Secret] = true
		}

		if len(details) >= 25 {
			break
		}
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

// ValidateTrial validates a single or bulk trial request on POST /api/trials/{protocol}.
func (v *Validator) ValidateTrial(protocol string, req *model.TrialRequest) []model.ErrorDetail {
	var details []model.ErrorDetail

	if !v.IsValidProtocol(protocol) {
		details = append(details, model.ErrorDetail{
			Field:   "protocol",
			Message: "must be ssh, vless, vmess, trojan, or noobz",
		})
	}

	if req.Count < 0 || req.Count > 1000 {
		details = append(details, model.ErrorDetail{
			Field:   "count",
			Message: "must be between 1 and 1000",
		})
	}

	if req.Prefix != "" && !v.prefixRegex.MatchString(req.Prefix) {
		details = append(details, model.ErrorDetail{
			Field:   "prefix",
			Message: "must be 1-16 alphanumeric characters or underscore",
		})
	}

	if !v.IsValidDuration(req.Duration) {
		details = append(details, model.ErrorDetail{
			Field:   "duration",
			Message: "must be in format: 30m, 2h, or 1d",
		})
	}

	if req.LimitIP < 0 || req.LimitIP > 1000 {
		details = append(details, model.ErrorDetail{
			Field:   "limit_ip",
			Message: "must be between 0 and 1000",
		})
	}

	return details
}

// ParseDuration converts a validated duration string ("30m", "2h", "7d") into a time.Duration.
func ParseDuration(duration string) (time.Duration, bool) {
	if len(duration) < 2 {
		return 0, false
	}
	unit := duration[len(duration)-1]
	num, err := strconv.Atoi(duration[:len(duration)-1])
	if err != nil || num <= 0 {
		return 0, false
	}
	switch unit {
	case 'm':
		return time.Duration(num) * time.Minute, true
	case 'h':
		return time.Duration(num) * time.Hour, true
	case 'd':
		return time.Duration(num) * 24 * time.Hour, true
	default:
		return 0, false
	}
}

// IsValidUsername checks if a username is safe and not a reserved Linux user.
func (v *Validator) IsValidUsername(username string) bool {
	if !v.usernameRegex.MatchString(username) {
		return false
	}
	return !reservedSystemUsers[strings.ToLower(username)]
}

// IsValidUUID checks if a UUID is valid.
func (v *Validator) IsValidUUID(uuid string) bool {
	return v.uuidRegex.MatchString(uuid)
}

// IsValidPassword checks if a password is safe for chpasswd/noobzvpns.
func (v *Validator) IsValidPassword(password string) bool {
	if len(password) < 1 || len(password) > 64 {
		return false
	}
	if strings.ContainsAny(password, " \t\n\r:\x00") {
		return false
	}
	for _, r := range password {
		if r < 33 || r > 126 {
			return false
		}
	}
	return true
}

// IsValidSecret checks if a Trojan/custom secret is safe for JSON and URLs.
func (v *Validator) IsValidSecret(secret string) bool {
	if len(secret) < 4 || len(secret) > 64 {
		return false
	}
	if strings.ContainsAny(secret, " \t\n\r:\"'\\`$;|&<>#\x00") {
		return false
	}
	for _, r := range secret {
		if r < 33 || r > 126 {
			return false
		}
	}
	return true
}

// IsValidDuration checks if a duration string is valid.
func (v *Validator) IsValidDuration(duration string) bool {
	if !v.durationRegex.MatchString(duration) {
		return false
	}
	_, ok := ParseDuration(duration)
	return ok
}

// IsValidProtocol checks if a protocol is valid.
func (v *Validator) IsValidProtocol(protocol string) bool {
	switch protocol {
	case "ssh", "vless", "vmess", "trojan", "noobz":
		return true
	default:
		return false
	}
}

// IsValidDomain checks if a domain query override is safe.
func (v *Validator) IsValidDomain(domain string) bool {
	return len(domain) <= 253 && v.domainRegex.MatchString(domain)
}

// IsValidService checks if a systemd service name and action are on the strict allowlist.
func (v *Validator) IsValidServiceAction(service, action string) bool {
	if !AllowedManagedServices[service] {
		return false
	}
	switch action {
	case "start", "stop", "restart":
		return true
	default:
		return false
	}
}
