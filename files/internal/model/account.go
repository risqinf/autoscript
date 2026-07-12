package model

import "time"

// Account represents a VPN account in the database.
type Account struct {
	ID         int64     `json:"id"`
	Protocol   string    `json:"protocol"`
	Username   string    `json:"username"`
	Secret     string    `json:"secret,omitempty"`
	QuotaBytes int64     `json:"quota_bytes"`
	UsedBytes  int64     `json:"used_bytes"`
	LimitIP    int       `json:"limit_ip"`
	ExpiredAt  time.Time `json:"expired_at"`
	Status     string    `json:"status"`
	CreatedAt  time.Time `json:"created_at"`
	UpdatedAt  time.Time `json:"updated_at"`
	Note       string    `json:"note,omitempty"`
}

// IsExpired returns true if the account has expired.
func (a *Account) IsExpired() bool {
	return time.Now().After(a.ExpiredAt)
}

// IsSuspended returns true if the account is suspended.
func (a *Account) IsSuspended() bool {
	return a.Status == "suspended"
}

// IsActive returns true if the account is active and not expired.
func (a *Account) IsActive() bool {
	return a.Status == "active" && !a.IsExpired()
}

// QuotaGB returns quota in gigabytes (0 = unlimited).
func (a *Account) QuotaGB() float64 {
	if a.QuotaBytes == 0 {
		return 0
	}
	return float64(a.QuotaBytes) / 1073741824
}

// UsedGB returns used bandwidth in gigabytes.
func (a *Account) UsedGB() float64 {
	return float64(a.UsedBytes) / 1073741824
}

// ServiceStatus represents the status of a system service.
type ServiceStatus struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Port   string `json:"port,omitempty"`
}

// SystemInfo represents system information.
type SystemInfo struct {
	Domain    string  `json:"domain"`
	IP        string  `json:"ip"`
	CPU       string  `json:"cpu"`
	Cores     int     `json:"cores"`
	RAMTotal  string  `json:"ram_total"`
	RAMUsed   string  `json:"ram_used"`
	SwapTotal string  `json:"swap_total"`
	SwapUsed  string  `json:"swap_used"`
	Uptime    string  `json:"uptime"`
	OS        string  `json:"os"`
}

// MonitorEntry represents a single login monitor entry.
type MonitorEntry struct {
	Username string   `json:"username"`
	IPCount  int      `json:"ip_count"`
	IPLimit  int      `json:"ip_limit"`
	IPs      []string `json:"ips"`
	UsedBytes int64   `json:"used_bytes"`
	QuotaBytes int64  `json:"quota_bytes"`
	ExpiredAt time.Time `json:"expired_at"`
}

// BandwidthEntry represents bandwidth usage.
type BandwidthEntry struct {
	Interface string `json:"interface"`
	RX        int64  `json:"rx"`
	TX        int64  `json:"tx"`
	Total     int64  `json:"total"`
}

// ConfigLink represents a generated configuration link.
type ConfigLink struct {
	Protocol string `json:"protocol"`
	Username string `json:"username"`
	Link     string `json:"link"`
	Remark   string `json:"remark,omitempty"`
}

// PortInfo represents available ports for a protocol.
type PortInfo struct {
	SSH        string `json:"ssh,omitempty"`
	WSHTTP     string `json:"ws_http,omitempty"`
	WSTLS      string `json:"ws_tls,omitempty"`
	BadVPN     string `json:"badvpn,omitempty"`
	OpenVPNTCP string `json:"openvpn_tcp,omitempty"`
}

// AccountDisplay represents the full account display with ports and config.
type AccountDisplay struct {
	Username  string    `json:"username"`
	Password  string    `json:"password,omitempty"`
	Domain    string    `json:"domain"`
	IP        string    `json:"ip"`
	LimitIP   int       `json:"limit_ip"`
	ExpiredAt time.Time `json:"expired_at"`
	Ports     PortInfo  `json:"ports"`
	Config    string    `json:"config,omitempty"`
}
