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

// SSHSubProtoStat represents traffic counters for one SSH sub-protocol.
type SSHSubProtoStat struct {
	SubProtocol string `json:"sub_protocol"`
	RXBytes     int64  `json:"rx_bytes"`
	TXBytes     int64  `json:"tx_bytes"`
	TotalBytes  int64  `json:"total_bytes"`
	HumanTotal  string `json:"human_total"`
	UpdatedAt   int64  `json:"updated_at,omitempty"`
}

// SSHProtoUsageBreakdown aggregates traffic across all 6 SSH sub-protocols.
type SSHProtoUsageBreakdown struct {
	OpenSSH  SSHSubProtoStat `json:"openssh"`  // Direct OpenSSH (:22, :3303)
	Dropbear SSHSubProtoStat `json:"dropbear"` // Direct Dropbear (:109, :143)
	SSHSSL   SSHSubProtoStat `json:"ssh_ssl"`  // Direct SSH SSL/TLS via HAProxy (:443, :8443 -> :109)
	SSHWS    SSHSubProtoStat `json:"ssh_ws"`   // SSH WebSocket HTTP/TLS (:80, :8080, :8888, :443)
	SlowDNS  SSHSubProtoStat `json:"slowdns"`  // DNSTT Tunnel (:53, :5300 UDP -> :109)
	OpenVPN  SSHSubProtoStat `json:"openvpn"`  // OpenVPN TCP/UDP (:1194)
	TotalRX  int64           `json:"total_rx"`
	TotalTX  int64           `json:"total_tx"`
	Total    int64           `json:"total_bytes"`
	Human    string          `json:"human_total"`
}

// SSHUserQuotaDetail represents detailed all-protocol SSH quota & live status for an account.
type SSHUserQuotaDetail struct {
	Username        string                 `json:"username"`
	Status          string                 `json:"status"`
	QuotaBytes      int64                  `json:"quota_bytes"`
	QuotaHuman      string                 `json:"quota_human"`
	UsedBytes       int64                  `json:"used_bytes"`
	UsedHuman       string                 `json:"used_human"`
	RemainingBytes  int64                  `json:"remaining_bytes"`
	RemainingHuman  string                 `json:"remaining_human"`
	UsagePercent    float64                `json:"usage_percent"`
	LimitIP         int                    `json:"limit_ip"`
	ActiveIPCount   int                    `json:"active_ip_count"`
	ActiveProtocols []string               `json:"active_protocols"`
	ExpiredAt       time.Time              `json:"expired_at"`
	Breakdown       SSHProtoUsageBreakdown `json:"breakdown"`
}

// SSHQuotaSummaryReport represents server-wide + per-user SSH All-Protocol quota usage.
type SSHQuotaSummaryReport struct {
	TotalAccounts     int                    `json:"total_accounts"`
	ActiveAccounts    int                    `json:"active_accounts"`
	SuspendedAccounts int                    `json:"suspended_accounts"`
	OnlineUsers       int                    `json:"online_users"`
	ServerBreakdown   SSHProtoUsageBreakdown `json:"server_breakdown"`
	Users             []SSHUserQuotaDetail   `json:"users"`
}

// ProtocolQuotaEntry represents quota status for any protocol user.
type ProtocolQuotaEntry struct {
	Protocol       string                  `json:"protocol"`
	Username       string                  `json:"username"`
	Status         string                  `json:"status"`
	QuotaBytes     int64                   `json:"quota_bytes"`
	QuotaHuman     string                  `json:"quota_human"`
	UsedBytes      int64                   `json:"used_bytes"`
	UsedHuman      string                  `json:"used_human"`
	RemainingBytes int64                   `json:"remaining_bytes"`
	UsagePercent   float64                 `json:"usage_percent"`
	LimitIP        int                     `json:"limit_ip"`
	ExpiredAt      time.Time               `json:"expired_at"`
	SSHBreakdown   *SSHProtoUsageBreakdown `json:"ssh_breakdown,omitempty"`
}

// GeoLocation represents enriched ISP/ASN and geographic location for a client IP.
type GeoLocation struct {
	IP          string  `json:"ip"`
	Country     string  `json:"country"`
	CountryCode string  `json:"country_code"`
	Region      string  `json:"region,omitempty"`
	City        string  `json:"city,omitempty"`
	ISP         string  `json:"isp"`
	Org         string  `json:"org,omitempty"`
	ASN         string  `json:"asn,omitempty"`
	Timezone    string  `json:"timezone,omitempty"`
	Latitude    float64 `json:"lat,omitempty"`
	Longitude   float64 `json:"lon,omitempty"`
	Source      string  `json:"source,omitempty"`
}

// AppActivity represents an application or domain currently accessed by a connected user.
type AppActivity struct {
	App         string `json:"app"`
	Category    string `json:"category"`
	Domain      string `json:"domain"`
	Destination string `json:"destination,omitempty"`
	Protocol    string `json:"protocol,omitempty"`
	Hits        int    `json:"hits"`
	LastSeen    string `json:"last_seen,omitempty"`
}

// ClientSessionDetail represents a single live connection/session for a connected user.
type ClientSessionDetail struct {
	ClientIP    string       `json:"client_ip"`
	Protocol    string       `json:"protocol"`
	SubProtocol string       `json:"sub_protocol"`
	Transport   string       `json:"transport"`
	ServerPort  string       `json:"server_port,omitempty"`
	VirtualIP   string       `json:"virtual_ip,omitempty"`
	PID         int          `json:"pid,omitempty"`
	RXBytes     int64        `json:"rx_bytes,omitempty"`
	TXBytes     int64        `json:"tx_bytes,omitempty"`
	TotalBytes  int64        `json:"total_bytes,omitempty"`
	ISP         string       `json:"isp,omitempty"`
	Location    string       `json:"location,omitempty"`
	Geo         *GeoLocation `json:"geo,omitempty"`
}

// MonitorEntry represents a single login monitor entry enriched with live protocol, ISP, GeoIP, and app/domain telemetry.
type MonitorEntry struct {
	Protocol        string                  `json:"protocol,omitempty"`
	Username        string                  `json:"username"`
	Status          string                  `json:"status,omitempty"`
	IPCount         int                     `json:"ip_count"`
	IPLimit         int                     `json:"ip_limit"`
	IPs             []string                `json:"ips"`
	Devices         []string                `json:"devices,omitempty"`
	ActiveProtocols []string                `json:"active_protocols,omitempty"`
	Transports      []string                `json:"transports,omitempty"`
	ISPs            []string                `json:"isps,omitempty"`
	Locations       []GeoLocation           `json:"locations,omitempty"`
	AccessedApps    []string                `json:"accessed_apps,omitempty"`
	AccessedDomains []string                `json:"accessed_domains,omitempty"`
	AppActivities   []AppActivity           `json:"app_activities,omitempty"`
	Sessions        []ClientSessionDetail   `json:"sessions,omitempty"`
	UsedBytes       int64                   `json:"used_bytes"`
	UsedHuman       string                  `json:"used_human,omitempty"`
	QuotaBytes      int64                   `json:"quota_bytes"`
	QuotaHuman      string                  `json:"quota_human,omitempty"`
	RemainingBytes  int64                   `json:"remaining_bytes,omitempty"`
	UsagePercent    float64                 `json:"usage_percent,omitempty"`
	SSHBreakdown    *SSHProtoUsageBreakdown `json:"ssh_breakdown,omitempty"`
	ExpiredAt       time.Time               `json:"expired_at"`
}

// UnifiedMonitorReport aggregates live connected users across ALL protocols.
type UnifiedMonitorReport struct {
	Timestamp        time.Time                 `json:"timestamp"`
	TotalOnlineUsers int                       `json:"total_online_users"`
	TotalConnections int                       `json:"total_connections"`
	ByProtocolCount  map[string]int            `json:"by_protocol_count"`
	TopApps          []string                  `json:"top_apps"`
	Protocols        map[string][]MonitorEntry `json:"protocols"`
}

// ServiceStatus represents the status of a system service.
type ServiceStatus struct {
	Name   string `json:"name"`
	Status string `json:"status"`
	Port   string `json:"port,omitempty"`
}

// SystemInfo represents detailed system & Rocky Linux optimization telemetry.
type SystemInfo struct {
	Domain          string  `json:"domain"`
	IP              string  `json:"ip"`
	CPU             string  `json:"cpu"`
	Cores           int     `json:"cores"`
	LoadAvg         string  `json:"load_avg"`
	RAMTotal        string  `json:"ram_total"`
	RAMUsed         string  `json:"ram_used"`
	RAMAvailable    string  `json:"ram_available"`
	RAMTotalMB      int64   `json:"ram_total_mb"`
	RAMUsedMB       int64   `json:"ram_used_mb"`
	RAMAvailableMB  int64   `json:"ram_available_mb"`
	RAMUsagePercent float64 `json:"ram_usage_percent"`
	SwapTotal       string  `json:"swap_total"`
	SwapUsed        string  `json:"swap_used"`
	ZRAMEnabled     bool    `json:"zram_enabled"`
	ZRAMTotalMB     int64   `json:"zram_total_mb"`
	ConntrackActive int64   `json:"conntrack_active"`
	ConntrackMax    int64   `json:"conntrack_max"`
	TCPCongestion   string  `json:"tcp_congestion"`
	Kernel          string  `json:"kernel"`
	RockyProfile    string  `json:"rocky_profile"`
	Uptime          string  `json:"uptime"`
	UptimeSeconds   int64   `json:"uptime_seconds"`
	OS              string  `json:"os"`
	APIVersion      string  `json:"api_version"`
	Goroutines      int     `json:"goroutines"`
}

// BandwidthPeriod represents a daily/monthly bandwidth bucket.
type BandwidthPeriod struct {
	Label   string `json:"label"`
	RXBytes int64  `json:"rx_bytes"`
	TXBytes int64  `json:"tx_bytes"`
	Total   int64  `json:"total_bytes"`
	Human   string `json:"human_total"`
}

// BandwidthEntry represents interface bandwidth usage.
type BandwidthEntry struct {
	Interface string            `json:"interface"`
	RX        int64             `json:"rx"`
	TX        int64             `json:"tx"`
	Total     int64             `json:"total"`
	HumanRX   string            `json:"human_rx"`
	HumanTX   string            `json:"human_tx"`
	HumanTot  string            `json:"human_total"`
	Daily     []BandwidthPeriod `json:"daily,omitempty"`
	Monthly   []BandwidthPeriod `json:"monthly,omitempty"`
}

// BandwidthReport represents full server bandwidth statistics.
type BandwidthReport struct {
	Source     string           `json:"source"`
	Interfaces []BandwidthEntry `json:"interfaces"`
	TotalRX    int64            `json:"total_rx"`
	TotalTX    int64            `json:"total_tx"`
	TotalBytes int64            `json:"total_bytes"`
	HumanTotal string           `json:"human_total"`
}

// ConfigLink represents a generated configuration link.
type ConfigLink struct {
	Protocol   string            `json:"protocol"`
	Username   string            `json:"username"`
	Link       string            `json:"link"`
	Remark     string            `json:"remark,omitempty"`
	Ports      *PortInfo         `json:"ports,omitempty"`
	Transports map[string]string `json:"transports,omitempty"`
}

// PortInfo represents available ports for protocols on the server.
type PortInfo struct {
	OpenSSH    string `json:"openssh,omitempty"`
	Dropbear   string `json:"dropbear,omitempty"`
	SSHSSL     string `json:"ssh_ssl,omitempty"`
	SSH        string `json:"ssh,omitempty"`
	WSHTTP     string `json:"ws_http,omitempty"`
	WSTLS      string `json:"ws_tls,omitempty"`
	BadVPN     string `json:"badvpn,omitempty"`
	OpenVPNTCP string `json:"openvpn_tcp,omitempty"`
	OpenVPNUDP string `json:"openvpn_udp,omitempty"`
	SquidProxy string `json:"squid_proxy,omitempty"`
	SlowDNS    string `json:"slowdns,omitempty"`
	HUHTTP     string `json:"hu_http,omitempty"`
	HUTLS      string `json:"hu_tls,omitempty"`
	XHTTPHTTP  string `json:"xhttp_http,omitempty"`
	XHTTPTLS   string `json:"xhttp_tls,omitempty"`
	GRPCTLS    string `json:"grpc_tls,omitempty"`
	NoobzTCP   string `json:"noobz_tcp,omitempty"`
	NoobzWS    string `json:"noobz_ws,omitempty"`
}

// SlowDNSDetail represents SlowDNS configuration details for accounts.
type SlowDNSDetail struct {
	Nameserver string `json:"nameserver,omitempty"`
	PublicKey  string `json:"public_key,omitempty"`
	Port       string `json:"port,omitempty"`
}

// SlowDNSStatus represents SlowDNS system service status and configuration.
type SlowDNSStatus struct {
	Status     string `json:"status"`
	Nameserver string `json:"nameserver,omitempty"`
	PublicKey  string `json:"public_key,omitempty"`
	Port       string `json:"port"`
	Target     string `json:"target"`
}

// AccountDisplay represents the full account display with ports and config.
type AccountDisplay struct {
	Username  string         `json:"username"`
	Password  string         `json:"password,omitempty"`
	Domain    string         `json:"domain"`
	IP        string         `json:"ip"`
	LimitIP   int            `json:"limit_ip"`
	ExpiredAt time.Time      `json:"expired_at"`
	Ports     PortInfo       `json:"ports"`
	Config    string         `json:"config,omitempty"`
	SlowDNS   *SlowDNSDetail `json:"slowdns,omitempty"`
}

// ProtocolSummary represents account counts and traffic totals per protocol.
type ProtocolSummary struct {
	Protocol       string `json:"protocol"`
	Total          int    `json:"total"`
	Active         int    `json:"active"`
	Suspended      int    `json:"suspended"`
	Expired        int    `json:"expired"`
	TotalUsedBytes int64  `json:"total_used_bytes"`
	TotalUsedHuman string `json:"total_used_human"`
}

// AuditLogEntry represents a row in the main audit_log table.
type AuditLogEntry struct {
	ID        int64     `json:"id"`
	Timestamp time.Time `json:"timestamp"`
	Actor     string    `json:"actor"`
	Action    string    `json:"action"`
	Protocol  string    `json:"protocol,omitempty"`
	Username  string    `json:"username,omitempty"`
	Detail    string    `json:"detail,omitempty"`
}

// BulkAccountOutput combines a provisioned Account with its ready-to-use ConfigLink.
type BulkAccountOutput struct {
	Account *Account    `json:"account"`
	Config  *ConfigLink `json:"config,omitempty"`
}

// BulkItemError records any per-item validation or conflict error in non-atomic fallback mode.
type BulkItemError struct {
	Index    int    `json:"index"`
	Username string `json:"username,omitempty"`
	Reason   string `json:"reason"`
}

// BulkCreateResult summarizes a high-speed Flash-Sale bulk account creation run.
type BulkCreateResult struct {
	Protocol       string              `json:"protocol"`
	RequestedCount int                 `json:"requested_count"`
	CreatedCount   int                 `json:"created_count"`
	FailedCount    int                 `json:"failed_count"`
	DurationMs     int64               `json:"duration_ms"`
	IdempotencyKey string              `json:"idempotency_key,omitempty"`
	Accounts       []BulkAccountOutput `json:"accounts"`
	Errors         []BulkItemError     `json:"errors,omitempty"`
}

// UserProtocolAccountDetail holds complete account, config, and live session state for one detected protocol.
type UserProtocolAccountDetail struct {
	Protocol           string        `json:"protocol"`
	Online             bool          `json:"online"`
	Status             string        `json:"status"`
	DaysRemaining      int           `json:"days_remaining"`
	ActiveIPCount      int           `json:"active_ip_count"`
	IPLimit            int           `json:"ip_limit"`
	ConnectedIPs       []string      `json:"connected_ips"`
	ActiveSubProtocols []string      `json:"active_sub_protocols,omitempty"`
	Transports         []string      `json:"transports,omitempty"`
	Account            *Account      `json:"account"`
	Config             *ConfigLink   `json:"config,omitempty"`
	LiveMonitor        *MonitorEntry `json:"live_monitor,omitempty"`
}

// UserQuotaOverview summarizes cumulative quota & bandwidth usage across all detected protocols for a user.
type UserQuotaOverview struct {
	QuotaBytes     int64                   `json:"quota_bytes"`
	QuotaHuman     string                  `json:"quota_human"`
	UsedBytes      int64                   `json:"used_bytes"`
	UsedHuman      string                  `json:"used_human"`
	RemainingBytes int64                   `json:"remaining_bytes"`
	RemainingHuman string                  `json:"remaining_human"`
	UsagePercent   float64                 `json:"usage_percent"`
	SSHBreakdown   *SSHProtoUsageBreakdown `json:"ssh_breakdown,omitempty"`
}

// UserAutoDetectReport provides unified auto-detected protocol, login status, ISP/GeoIP, app/domain, quota, and config telemetry for a username.
type UserAutoDetectReport struct {
	Username          string                      `json:"username"`
	Online            bool                        `json:"online"`
	AccountStatus     string                      `json:"account_status"`
	PrimaryProtocol   string                      `json:"primary_protocol"`
	DetectedProtocols []string                    `json:"detected_protocols"`
	ActiveProtocols   []string                    `json:"active_protocols"`
	ActiveTransports  []string                    `json:"active_transports"`
	TotalActiveIPs    int                         `json:"total_active_ips"`
	IPLimit           int                         `json:"ip_limit"`
	ConnectedIPs      []string                    `json:"connected_ips"`
	ISPs              []string                    `json:"isps"`
	Locations         []GeoLocation               `json:"locations"`
	AccessedApps      []string                    `json:"accessed_apps"`
	AccessedDomains   []string                    `json:"accessed_domains"`
	AppActivities     []AppActivity               `json:"app_activities"`
	Sessions          []ClientSessionDetail       `json:"sessions"`
	QuotaSummary      UserQuotaOverview           `json:"quota_summary"`
	Accounts          []UserProtocolAccountDetail `json:"accounts"`
	CheckedAt         time.Time                   `json:"checked_at"`
}
