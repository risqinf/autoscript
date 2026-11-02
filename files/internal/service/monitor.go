package service

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/cache"
	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
)

const AppVersion = "5.6.0"

// MonitorService defines the interface for system, bandwidth, quota, and live session telemetry.
type MonitorService interface {
	GetServiceStatus(ctx context.Context) ([]model.ServiceStatus, error)
	ControlService(ctx context.Context, serviceName, action string) error
	RunRockyOptimization(ctx context.Context) (map[string]string, error)
	GetSlowDNSInfo(ctx context.Context) (*model.SlowDNSStatus, error)
	GetSystemInfo(ctx context.Context) (*model.SystemInfo, error)
	GetBandwidth(ctx context.Context) (*model.BandwidthReport, error)

	GetMonitorEntries(ctx context.Context, protocol string) ([]model.MonitorEntry, error)
	GetUnifiedMonitor(ctx context.Context) (*model.UnifiedMonitorReport, error)
	GetUserActivity(ctx context.Context, protocol, username string) (*model.MonitorEntry, error)
	LookupUserAutoDetect(ctx context.Context, username string, xraySvc XrayService) (*model.UserAutoDetectReport, error)

	GetSSHAllProtocolQuota(ctx context.Context) (*model.SSHQuotaSummaryReport, error)
	GetSSHUserQuota(ctx context.Context, username string) (*model.SSHUserQuotaDetail, error)
	GetProtocolQuotaList(ctx context.Context, protocol string) ([]model.ProtocolQuotaEntry, error)
	GetUserQuota(ctx context.Context, protocol, username string) (*model.ProtocolQuotaEntry, error)

	BatchQueryXrayStats(ctx context.Context) map[string]int64
}

// monitorService implements MonitorService with Singleflight micro-TTL caching and batch GeoIP/App telemetry.
type monitorService struct {
	repo       repository.AccountRepository
	config     *config.Config
	logger     *zerolog.Logger
	snap       *cache.SnapshotCache
	geo        *GeoIPResolver
	httpClient *http.Client
}

// NewMonitorService creates a new MonitorService.
func NewMonitorService(repo repository.AccountRepository, cfg *config.Config, logger *zerolog.Logger) MonitorService {
	return NewMonitorServiceWithCache(repo, cfg, cache.NewSnapshotCache(), logger)
}

// NewMonitorServiceWithCache creates a MonitorService sharing a SnapshotCache with AccountService.
func NewMonitorServiceWithCache(repo repository.AccountRepository, cfg *config.Config, snap *cache.SnapshotCache, logger *zerolog.Logger) MonitorService {
	if snap == nil {
		snap = cache.NewSnapshotCache()
	}
	geoCachePath := ""
	if cfg != nil {
		geoCachePath = cfg.GeoIPCacheFile
	}
	return &monitorService{
		repo:   repo,
		config: cfg,
		logger: logger,
		snap:   snap,
		geo:    NewGeoIPResolver(geoCachePath),
		httpClient: &http.Client{
			Timeout: 900 * time.Millisecond,
		},
	}
}

// GetServiceStatus returns the status of all VPN stack services (coalesced for 2s).
func (s *monitorService) GetServiceStatus(ctx context.Context) ([]model.ServiceStatus, error) {
	val, err := s.snap.GetOrLoad("sys:services", 2*time.Second, func() (interface{}, error) {
		services := []struct {
			name string
			port string
		}{
			{"haproxy", "80, 8080, 443, 8443"},
			{"nginx", "81 (H1), 82 (H2)"},
			{"xray", "10011-10033"},
			{"dropbear", "109, 143"},
			{"ssh-ws", "8888, 8081"},
			{"sshd", "22, 3303"},
			{"squid", "3128, 8000"},
			{"openvpn-server@server-tcp-1194", "1194"},
			{"slowdns", "53, 5300 (UDP)"},
			{"noobzvpns", "8585"},
			{"loop-quota-ssh", "all-ssh-quota"},
			{"loop-limit-ssh", "ip-enforcer"},
			{"loop-quota-xray", "xray-quota"},
			{"loop-limit-xray", "xray-ip-enforcer"},
			{"vnstat", "telemetry"},
			{"firewalld", "security"},
		}

		names := make([]string, len(services))
		for i, svc := range services {
			names[i] = svc.name
		}

		// Query all services in a single `systemctl is-active` invocation (16x faster than 16 forks!)
		activeStates := make([]string, 0, len(services))
		if !isTestMode() {
			cmd := exec.CommandContext(ctx, "systemctl", append([]string{"is-active"}, names...)...)
			out, _ := cmd.Output()
			if len(out) > 0 {
				activeStates = strings.Split(strings.TrimSpace(string(out)), "\n")
			}
		}

		statuses := make([]model.ServiceStatus, len(services))
		for i, svc := range services {
			st := "inactive"
			if i < len(activeStates) && strings.TrimSpace(activeStates[i]) == "active" {
				st = "active"
			}
			statuses[i] = model.ServiceStatus{
				Name:   svc.name,
				Status: st,
				Port:   svc.port,
			}
		}
		return statuses, nil
	})
	if err != nil {
		return nil, err
	}
	return val.([]model.ServiceStatus), nil
}

// ControlService starts, stops, or restarts an allowlisted VPN daemon.
func (s *monitorService) ControlService(ctx context.Context, serviceName, action string) error {
	if !validator.AllowedManagedServices[serviceName] {
		return model.ErrInvalidService
	}
	if action != "start" && action != "stop" && action != "restart" {
		return model.ErrInvalidService
	}
	cmd := exec.CommandContext(ctx, "systemctl", action, serviceName)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl %s %s: %s: %w", action, serviceName, strings.TrimSpace(string(out)), err)
	}
	s.snap.InvalidatePrefix("sys:")
	return nil
}

// RunRockyOptimization triggers Rocky Linux extreme kernel/ZRAM tuning and firewall/SELinux healing.
func (s *monitorService) RunRockyOptimization(ctx context.Context) (map[string]string, error) {
	result := map[string]string{
		"firewall": "skipped",
		"rocky":    "skipped",
	}
	if _, err := os.Stat("/usr/local/sbin/fix-firewall"); err == nil {
		if out, err := exec.CommandContext(ctx, "/usr/local/sbin/fix-firewall", "--quiet").CombinedOutput(); err != nil {
			result["firewall"] = "warning: " + strings.TrimSpace(string(out))
		} else {
			result["firewall"] = "applied"
		}
	}
	if _, err := os.Stat("/usr/local/sbin/optimize-rocky"); err == nil {
		if out, err := exec.CommandContext(ctx, "/usr/local/sbin/optimize-rocky", "--quiet").CombinedOutput(); err != nil {
			result["rocky"] = "warning: " + strings.TrimSpace(string(out))
		} else {
			result["rocky"] = "applied"
		}
	}
	s.snap.InvalidatePrefix("sys:")
	return result, nil
}

// GetSlowDNSInfo returns SlowDNS service and key configuration.
func (s *monitorService) GetSlowDNSInfo(ctx context.Context) (*model.SlowDNSStatus, error) {
	val, err := s.snap.GetOrLoad("sys:slowdns", 3*time.Second, func() (interface{}, error) {
		status := "inactive"
		if !isTestMode() {
			cmd := exec.CommandContext(ctx, "systemctl", "is-active", "slowdns")
			if output, err := cmd.Output(); err == nil && strings.TrimSpace(string(output)) == "active" {
				status = "active"
			}
		}

		ns := ""
		if b, err := os.ReadFile("/etc/slowdns/nameserver"); err == nil {
			ns = strings.TrimSpace(string(b))
		}
		pub := ""
		if b, err := os.ReadFile("/etc/slowdns/server.pub"); err == nil {
			pub = strings.TrimSpace(string(b))
		}

		return &model.SlowDNSStatus{
			Status:     status,
			Nameserver: ns,
			PublicKey:  pub,
			Port:       "53 / 5300 UDP",
			Target:     "127.0.0.1:109 (Dropbear)",
		}, nil
	})
	if err != nil {
		return nil, err
	}
	return val.(*model.SlowDNSStatus), nil
}

// GetSystemInfo reads OS, CPU, RAM, ZRAM, Conntrack, and Rocky Linux profile directly from /proc without spawning shells.
func (s *monitorService) GetSystemInfo(ctx context.Context) (*model.SystemInfo, error) {
	val, err := s.snap.GetOrLoad("sys:info", 2*time.Second, func() (interface{}, error) {
		info := &model.SystemInfo{
			Domain:     s.config.Domain(),
			IP:         detectPrimaryLocalIP(),
			Cores:      runtime.NumCPU(),
			APIVersion: AppVersion,
			Goroutines: runtime.NumGoroutine(),
		}

		// CPU Model from /proc/cpuinfo
		if f, err := os.Open("/proc/cpuinfo"); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := sc.Text()
				if strings.HasPrefix(line, "model name") || strings.HasPrefix(line, "Hardware") {
					if idx := strings.IndexByte(line, ':'); idx >= 0 {
						info.CPU = strings.TrimSpace(line[idx+1:])
						break
					}
				}
			}
			_ = f.Close()
		}
		if info.CPU == "" {
			info.CPU = runtime.GOARCH + " vCPU"
		}

		// Load average from /proc/loadavg
		if b, err := os.ReadFile("/proc/loadavg"); err == nil {
			fields := strings.Fields(string(b))
			if len(fields) >= 3 {
				info.LoadAvg = fields[0] + ", " + fields[1] + ", " + fields[2]
			}
		}

		// RAM & Swap from /proc/meminfo
		var memTotalKB, memAvailKB, swapTotalKB, swapFreeKB int64
		if f, err := os.Open("/proc/meminfo"); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				fields := strings.Fields(sc.Text())
				if len(fields) < 2 {
					continue
				}
				v, _ := strconv.ParseInt(fields[1], 10, 64)
				switch fields[0] {
				case "MemTotal:":
					memTotalKB = v
				case "MemAvailable:":
					memAvailKB = v
				case "SwapTotal:":
					swapTotalKB = v
				case "SwapFree:":
					swapFreeKB = v
				}
			}
			_ = f.Close()
		}
		memUsedKB := memTotalKB - memAvailKB
		if memUsedKB < 0 {
			memUsedKB = 0
		}
		swapUsedKB := swapTotalKB - swapFreeKB
		if swapUsedKB < 0 {
			swapUsedKB = 0
		}

		info.RAMTotalMB = memTotalKB / 1024
		info.RAMUsedMB = memUsedKB / 1024
		info.RAMAvailableMB = memAvailKB / 1024
		info.RAMTotal = fmt.Sprintf("%d MB", info.RAMTotalMB)
		info.RAMUsed = fmt.Sprintf("%d MB", info.RAMUsedMB)
		info.RAMAvailable = fmt.Sprintf("%d MB", info.RAMAvailableMB)
		if memTotalKB > 0 {
			info.RAMUsagePercent = float64(memUsedKB*1000/memTotalKB) / 10.0
		}
		info.SwapTotal = fmt.Sprintf("%d MB", swapTotalKB/1024)
		info.SwapUsed = fmt.Sprintf("%d MB", swapUsedKB/1024)

		// ZRAM status
		if b, err := os.ReadFile("/sys/block/zram0/disksize"); err == nil {
			if sz, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil && sz > 0 {
				info.ZRAMEnabled = true
				info.ZRAMTotalMB = sz / (1024 * 1024)
			}
		}

		// Rocky Linux Optimization Tier
		switch {
		case info.RAMTotalMB <= 1536:
			info.RockyProfile = "1GB-EXTREME"
		case info.RAMTotalMB <= 3072:
			info.RockyProfile = "2GB-OPTIMIZED"
		case info.RAMTotalMB <= 6144:
			info.RockyProfile = "4GB-HIGH"
		default:
			info.RockyProfile = "8GB+-ENTERPRISE"
		}

		// Conntrack & TCP Congestion
		if b, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_count"); err == nil {
			info.ConntrackActive, _ = strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
		}
		if b, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_max"); err == nil {
			info.ConntrackMax, _ = strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64)
		}
		if b, err := os.ReadFile("/proc/sys/net/ipv4/tcp_congestion_control"); err == nil {
			info.TCPCongestion = strings.TrimSpace(string(b))
		}
		if b, err := os.ReadFile("/proc/sys/kernel/osrelease"); err == nil {
			info.Kernel = strings.TrimSpace(string(b))
		}

		// Uptime from /proc/uptime
		if b, err := os.ReadFile("/proc/uptime"); err == nil {
			fields := strings.Fields(string(b))
			if len(fields) >= 1 {
				if secFloat, err := strconv.ParseFloat(fields[0], 64); err == nil {
					sec := int64(secFloat)
					info.UptimeSeconds = sec
					days := sec / 86400
					hours := (sec % 86400) / 3600
					mins := (sec % 3600) / 60
					if days > 0 {
						info.Uptime = fmt.Sprintf("%dd %dh %dm", days, hours, mins)
					} else {
						info.Uptime = fmt.Sprintf("%dh %dm", hours, mins)
					}
				}
			}
		}

		// OS Pretty Name from /etc/os-release
		if f, err := os.Open("/etc/os-release"); err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := sc.Text()
				if strings.HasPrefix(line, "PRETTY_NAME=") {
					info.OS = strings.Trim(strings.TrimPrefix(line, "PRETTY_NAME="), `"'`)
					break
				}
			}
			_ = f.Close()
		}

		return info, nil
	})
	if err != nil {
		return nil, err
	}
	return val.(*model.SystemInfo), nil
}

// GetBandwidth returns server bandwidth statistics via vnstat --json with pure-Go /proc/net/dev fallback.
func (s *monitorService) GetBandwidth(ctx context.Context) (*model.BandwidthReport, error) {
	val, err := s.snap.GetOrLoad("sys:bandwidth", 3*time.Second, func() (interface{}, error) {
		if rep, ok := s.readVnstatJSON(ctx); ok {
			return rep, nil
		}
		return s.readProcNetDev(), nil
	})
	if err != nil {
		return nil, err
	}
	return val.(*model.BandwidthReport), nil
}

func (s *monitorService) readVnstatJSON(ctx context.Context) (*model.BandwidthReport, bool) {
	if isTestMode() {
		return nil, false
	}
	cmd := exec.CommandContext(ctx, "vnstat", "--json")
	out, err := cmd.Output()
	if err != nil || len(out) == 0 {
		return nil, false
	}

	var parsed struct {
		Interfaces []struct {
			Name    string `json:"name"`
			Traffic struct {
				Total struct {
					RX int64 `json:"rx"`
					TX int64 `json:"tx"`
				} `json:"total"`
				Day []struct {
					Date struct {
						Year  int `json:"year"`
						Month int `json:"month"`
						Day   int `json:"day"`
					} `json:"date"`
					RX int64 `json:"rx"`
					TX int64 `json:"tx"`
				} `json:"day"`
				Month []struct {
					Date struct {
						Year  int `json:"year"`
						Month int `json:"month"`
					} `json:"date"`
					RX int64 `json:"rx"`
					TX int64 `json:"tx"`
				} `json:"month"`
			} `json:"traffic"`
		} `json:"interfaces"`
	}

	if err := json.Unmarshal(out, &parsed); err != nil || len(parsed.Interfaces) == 0 {
		return nil, false
	}

	rep := &model.BandwidthReport{
		Source:     "vnstat",
		Interfaces: make([]model.BandwidthEntry, 0, len(parsed.Interfaces)),
	}

	for _, iface := range parsed.Interfaces {
		if iface.Name == "lo" {
			continue
		}
		rx := iface.Traffic.Total.RX
		tx := iface.Traffic.Total.TX
		tot := rx + tx

		entry := model.BandwidthEntry{
			Interface: iface.Name,
			RX:        rx,
			TX:        tx,
			Total:     tot,
			HumanRX:   repository.FormatBytes(rx),
			HumanTX:   repository.FormatBytes(tx),
			HumanTot:  repository.FormatBytes(tot),
		}

		// Last 7 days
		startDay := 0
		if len(iface.Traffic.Day) > 7 {
			startDay = len(iface.Traffic.Day) - 7
		}
		for _, d := range iface.Traffic.Day[startDay:] {
			dtot := d.RX + d.TX
			entry.Daily = append(entry.Daily, model.BandwidthPeriod{
				Label:   fmt.Sprintf("%04d-%02d-%02d", d.Date.Year, d.Date.Month, d.Date.Day),
				RXBytes: d.RX,
				TXBytes: d.TX,
				Total:   dtot,
				Human:   repository.FormatBytes(dtot),
			})
		}

		// Last 6 months
		startMon := 0
		if len(iface.Traffic.Month) > 6 {
			startMon = len(iface.Traffic.Month) - 6
		}
		for _, m := range iface.Traffic.Month[startMon:] {
			mtot := m.RX + m.TX
			entry.Monthly = append(entry.Monthly, model.BandwidthPeriod{
				Label:   fmt.Sprintf("%04d-%02d", m.Date.Year, m.Date.Month),
				RXBytes: m.RX,
				TXBytes: m.TX,
				Total:   mtot,
				Human:   repository.FormatBytes(mtot),
			})
		}

		rep.Interfaces = append(rep.Interfaces, entry)
		rep.TotalRX += rx
		rep.TotalTX += tx
	}

	if len(rep.Interfaces) == 0 {
		return nil, false
	}
	rep.TotalBytes = rep.TotalRX + rep.TotalTX
	rep.HumanTotal = repository.FormatBytes(rep.TotalBytes)
	return rep, true
}

func (s *monitorService) readProcNetDev() *model.BandwidthReport {
	rep := &model.BandwidthReport{
		Source:     "proc_net_dev",
		Interfaces: make([]model.BandwidthEntry, 0, 2),
	}

	f, err := os.Open("/proc/net/dev")
	if err != nil {
		rep.HumanTotal = "0 B"
		return rep
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	lineNo := 0
	for sc.Scan() {
		lineNo++
		if lineNo <= 2 {
			continue
		}
		parts := strings.SplitN(sc.Text(), ":", 2)
		if len(parts) != 2 {
			continue
		}
		iface := strings.TrimSpace(parts[0])
		if iface == "lo" || strings.HasPrefix(iface, "tun") || strings.HasPrefix(iface, "veth") {
			continue
		}
		fields := strings.Fields(parts[1])
		if len(fields) < 9 {
			continue
		}
		rx, _ := strconv.ParseInt(fields[0], 10, 64)
		tx, _ := strconv.ParseInt(fields[8], 10, 64)
		tot := rx + tx
		rep.Interfaces = append(rep.Interfaces, model.BandwidthEntry{
			Interface: iface,
			RX:        rx,
			TX:        tx,
			Total:     tot,
			HumanRX:   repository.FormatBytes(rx),
			HumanTX:   repository.FormatBytes(tx),
			HumanTot:  repository.FormatBytes(tot),
		})
		rep.TotalRX += rx
		rep.TotalTX += tx
	}
	rep.TotalBytes = rep.TotalRX + rep.TotalTX
	rep.HumanTotal = repository.FormatBytes(rep.TotalBytes)
	return rep
}

// ---------------------------------------------------------------------------
// SSH ALL-PROTOCOL LIVE SESSION, QUOTA, APP/DOMAIN, ISP & GEOIP ENGINE
// Covers: OpenSSH (:22,:3303), Dropbear (:109,:143), Direct SSH SSL/TLS (:443,:8443),
//         SSH WebSocket (:80,:8080,:8888,:443), SlowDNS (:53,:5300), OpenVPN (:1194)
// ---------------------------------------------------------------------------

type rawSSHSession struct {
	Username    string
	ClientIP    string
	SubProtocol string
	Transport   string
	ServerPort  string
	VirtualIP   string
	PID         int
	RXBytes     int64
	TXBytes     int64
}

type socketRow struct {
	LocalAddr string
	LocalPort string
	PeerAddr  string
	PeerPort  string
	ProcName  string
	PID       int
	RXBytes   int64
	TXBytes   int64
}

var (
	reSSProc      = regexp.MustCompile(`users:\(\("([^"]+)",pid=(\d+)`)
	reBytesRecv   = regexp.MustCompile(`bytes_received:(\d+)`)
	reBytesAcked  = regexp.MustCompile(`bytes_acked:(\d+)`)
	reXrayLogLine = regexp.MustCompile(`^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})(?:\.\d+)?\s+from\s+(?:tcp:|udp:)?(\[?[0-9a-fA-F:.]+\]?):\d+\s+accepted\s+(tcp|udp):([^\s]+)\s+\[([^\]]+)\]\s+email:\s*(\S+)`)
)

func parseAddrPort(token string) (string, string) {
	token = strings.TrimSpace(token)
	idx := strings.LastIndexByte(token, ':')
	if idx < 0 {
		return token, ""
	}
	addr := token[:idx]
	port := token[idx+1:]
	addr = strings.TrimPrefix(strings.TrimSuffix(addr, "]"), "[")
	if idxPct := strings.IndexByte(addr, '%'); idxPct > 0 {
		addr = addr[:idxPct]
	}
	addr = strings.TrimPrefix(addr, "::ffff:")
	return addr, port
}

func readSocketSnapshot(ctx context.Context) []socketRow {
	if isTestMode() {
		return nil
	}
	cmdCtx, cancel := context.WithTimeout(ctx, 1200*time.Millisecond)
	defer cancel()

	// `ss -tinpH` outputs 2 lines per TCP established socket: header line + TCP info metrics line
	out, err := exec.CommandContext(cmdCtx, "ss", "-tinpH").Output()
	if err != nil || len(out) == 0 {
		return nil
	}

	var rows []socketRow
	lines := strings.Split(string(out), "\n")
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		// Header lines start with ESTAB / SYN-SENT / CLOSE-WAIT etc.
		fields := strings.Fields(line)
		if len(fields) < 5 {
			continue
		}
		if fields[0] != "ESTAB" {
			continue
		}

		lAddr, lPort := parseAddrPort(fields[3])
		pAddr, pPort := parseAddrPort(fields[4])
		row := socketRow{
			LocalAddr: lAddr,
			LocalPort: lPort,
			PeerAddr:  pAddr,
			PeerPort:  pPort,
		}
		if m := reSSProc.FindStringSubmatch(line); len(m) >= 3 {
			row.ProcName = m[1]
			row.PID, _ = strconv.Atoi(m[2])
		}

		// Check if next line is the indented TCP info metrics line
		if i+1 < len(lines) {
			nextLine := lines[i+1]
			if strings.HasPrefix(nextLine, "\t") || strings.HasPrefix(nextLine, " ") {
				if m := reBytesRecv.FindStringSubmatch(nextLine); len(m) >= 2 {
					row.RXBytes, _ = strconv.ParseInt(m[1], 10, 64)
				}
				if m := reBytesAcked.FindStringSubmatch(nextLine); len(m) >= 2 {
					row.TXBytes, _ = strconv.ParseInt(m[1], 10, 64)
				}
				i++
			}
		}

		rows = append(rows, row)
	}
	return rows
}

func resolvePIDUsername(pid int, uidCache map[string]string) string {
	if pid <= 0 {
		return ""
	}
	// Check /proc/<pid>/status Uid
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "Uid:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				uidStr := fields[1]
				uidInt, _ := strconv.Atoi(uidStr)
				if uidInt >= 1000 && uidInt < 65534 {
					if cached, ok := uidCache[uidStr]; ok {
						return cached
					}
					if u, err := user.LookupId(uidStr); err == nil && u != nil {
						uidCache[uidStr] = u.Username
						return u.Username
					}
				}
			}
			break
		}
	}

	// For Dropbear child processes running as root (UID 0), inspect /proc/<pid>/cmdline or match auth logs / child processes
	cmdline, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err == nil && len(cmdline) > 0 {
		clean := strings.ReplaceAll(string(cmdline), "\x00", " ")
		// sshd: username [priv] or sshd: username@pts/0 or sshd: username@notty
		if strings.Contains(clean, "sshd:") {
			after := strings.TrimSpace(strings.SplitN(clean, "sshd:", 2)[1])
			uname := strings.Fields(after)[0]
			uname = strings.SplitN(uname, "@", 2)[0]
			if uname != "" && uname != "root" && uname != "[accepted]" && uname != "[net]" {
				return uname
			}
		}
	}
	return ""
}

func mapDropbearPIDToUser(validUsers map[string]bool) map[int]string {
	pidToUser := make(map[int]string)
	// Parse recent journal / secure log lines: "dropbear[PID]: Password auth succeeded for 'USER'"
	logFiles := []string{"/var/log/secure", "/var/log/auth.log", "/var/log/messages"}
	reAuth := regexp.MustCompile(`dropbear\[(\d+)\]:\s+(?:Password|Pubkey)\s+auth\s+succeeded\s+for\s+'([^']+)'`)
	for _, lf := range logFiles {
		f, err := os.Open(lf)
		if err != nil {
			continue
		}
		if st, err := f.Stat(); err == nil && st.Size() > 524288 {
			_, _ = f.Seek(st.Size()-524288, io.SeekStart)
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			m := reAuth.FindStringSubmatch(sc.Text())
			if len(m) >= 3 {
				pid, _ := strconv.Atoi(m[1])
				uname := m[2]
				if pid > 0 && (len(validUsers) == 0 || validUsers[uname]) {
					pidToUser[pid] = uname
				}
			}
		}
		_ = f.Close()
	}

	// If journald-only (no /var/log/secure), query journalctl -u dropbear -n 200
	if len(pidToUser) == 0 && !isTestMode() {
		ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
		out, err := exec.CommandContext(ctx, "journalctl", "-u", "dropbear", "--no-pager", "-n", "200").Output()
		cancel()
		if err == nil && len(out) > 0 {
			for _, line := range strings.Split(string(out), "\n") {
				m := reAuth.FindStringSubmatch(line)
				if len(m) >= 3 {
					pid, _ := strconv.Atoi(m[1])
					uname := m[2]
					if pid > 0 && (len(validUsers) == 0 || validUsers[uname]) {
						pidToUser[pid] = uname
					}
				}
			}
		}
	}
	return pidToUser
}

func (s *monitorService) collectLiveSSHSessions(ctx context.Context, validUsers map[string]bool) ([]rawSSHSession, map[int][]string, map[string][]string) {
	var sessions []rawSSHSession
	pidOutboundDests := make(map[int][]string)
	vipOutboundDests := make(map[string][]string)

	sockets := readSocketSnapshot(ctx)
	uidCache := make(map[string]string, 64)
	dropbearUsers := mapDropbearPIDToUser(validUsers)

	// Step 1: Query ssh-ws local session API (:8081) for exact WebSocket sessions & real client IPs
	wsPortToClient := make(map[string]struct {
		Username string
		ClientIP string
		RX       int64
		TX       int64
	})
	if s.config != nil && s.config.SSHWSAPI != "" {
		reqCtx, cancel := context.WithTimeout(ctx, 700*time.Millisecond)
		req, err := http.NewRequestWithContext(reqCtx, "GET", s.config.SSHWSAPI+"/api/sessions", nil)
		if err == nil {
			if resp, err := s.httpClient.Do(req); err == nil {
				var wsResp struct {
					Success bool `json:"success"`
					Data    struct {
						Sessions []struct {
							Username     string `json:"username"`
							RealClientIP string `json:"real_client_ip"`
							BackendAddr  string `json:"backend_addr"`
							LocalAddr    string `json:"local_addr"`
							TxBytes      int64  `json:"tx_bytes"`
							RxBytes      int64  `json:"rx_bytes"`
						} `json:"sessions"`
					} `json:"data"`
				}
				if json.NewDecoder(resp.Body).Decode(&wsResp) == nil {
					for _, ws := range wsResp.Data.Sessions {
						if ws.Username == "" || ws.Username == "detecting..." {
							continue
						}
						cIP := strings.Split(ws.RealClientIP, ":")[0]
						if cIP == "" {
							cIP = "127.0.0.1"
						}
						sessions = append(sessions, rawSSHSession{
							Username:    ws.Username,
							ClientIP:    cIP,
							SubProtocol: "ssh_ws",
							Transport:   "SSH WebSocket (HTTP/TLS)",
							ServerPort:  "80/443/8888",
							RXBytes:     ws.RxBytes,
							TXBytes:     ws.TxBytes,
						})
						if _, lPort := parseAddrPort(ws.LocalAddr); lPort != "" {
							wsPortToClient[lPort] = struct {
								Username string
								ClientIP string
								RX       int64
								TX       int64
							}{ws.Username, cIP, ws.RxBytes, ws.TxBytes}
						}
					}
				}
				_ = resp.Body.Close()
			}
		}
		cancel()
	}

	// Step 2: Build loopback peer correlation maps (HAProxy SSL :443/:8443 -> :109, ssh-ws -> :109, dnstt-server -> :109)
	localClientBySport := make(map[string]socketRow)
	haproxyExtClients := make([]string, 0, 8)
	for _, sk := range sockets {
		if (sk.PeerAddr == "127.0.0.1" || sk.PeerAddr == "::1") && (sk.PeerPort == "109" || sk.PeerPort == "143") {
			localClientBySport[sk.LocalPort] = sk
		}
		if sk.ProcName == "haproxy" && (sk.LocalPort == "443" || sk.LocalPort == "8443") && sk.PeerAddr != "127.0.0.1" && sk.PeerAddr != "::1" {
			haproxyExtClients = append(haproxyExtClients, sk.PeerAddr)
		}
	}

	// Step 3: Classify OpenSSH, Dropbear, SSH SSL/TLS, SlowDNS, and collect outbound destinations per PID!
	inboundPorts := map[string]bool{
		"22": true, "3303": true, "109": true, "143": true,
		"80": true, "81": true, "82": true, "443": true, "8080": true, "8443": true, "8888": true,
		"1194": true, "3128": true, "8000": true, "8585": true, "9000": true, "8081": true,
	}

	haproxyCursor := 0
	for _, sk := range sockets {
		// Outbound connection initiated by sshd / dropbear tunnel (dynamic/direct-tcpip port forwarding!)
		if (sk.ProcName == "sshd" || sk.ProcName == "dropbear") && !inboundPorts[sk.LocalPort] {
			if sk.PeerAddr != "" && sk.PeerAddr != "127.0.0.1" && sk.PeerAddr != "::1" {
				pidOutboundDests[sk.PID] = append(pidOutboundDests[sk.PID], net.JoinHostPort(sk.PeerAddr, sk.PeerPort))
			}
			continue
		}

		// OpenSSH Direct (:22, :3303)
		if sk.ProcName == "sshd" && (sk.LocalPort == "22" || sk.LocalPort == "3303") {
			uname := resolvePIDUsername(sk.PID, uidCache)
			if uname == "" || (len(validUsers) > 0 && !validUsers[uname]) {
				continue
			}
			cIP := sk.PeerAddr
			subProto := "openssh"
			transport := "OpenSSH Direct (:" + sk.LocalPort + ")"
			if cIP == "127.0.0.1" || cIP == "::1" {
				if caller, ok := localClientBySport[sk.PeerPort]; ok && caller.ProcName == "haproxy" {
					subProto = "ssh_ssl"
					transport = "Direct SSH SSL/TLS (:443)"
					if haproxyCursor < len(haproxyExtClients) {
						cIP = haproxyExtClients[haproxyCursor]
						haproxyCursor++
					}
				}
			}
			sessions = append(sessions, rawSSHSession{
				Username:    uname,
				ClientIP:    cIP,
				SubProtocol: subProto,
				Transport:   transport,
				ServerPort:  sk.LocalPort,
				PID:         sk.PID,
				RXBytes:     sk.RXBytes,
				TXBytes:     sk.TXBytes,
			})
			continue
		}

		// Dropbear (:109, :143) -> Direct Dropbear OR SSH-SSL/TLS (HAProxy) OR SlowDNS (dnstt-server) OR SSH-WS
		if sk.ProcName == "dropbear" && (sk.LocalPort == "109" || sk.LocalPort == "143") {
			uname := dropbearUsers[sk.PID]
			if uname == "" {
				uname = resolvePIDUsername(sk.PID, uidCache)
			}

			if sk.PeerAddr != "127.0.0.1" && sk.PeerAddr != "::1" {
				if uname != "" && (len(validUsers) == 0 || validUsers[uname]) {
					sessions = append(sessions, rawSSHSession{
						Username:    uname,
						ClientIP:    sk.PeerAddr,
						SubProtocol: "dropbear",
						Transport:   "Dropbear Direct (:" + sk.LocalPort + ")",
						ServerPort:  sk.LocalPort,
						PID:         sk.PID,
						RXBytes:     sk.RXBytes,
						TXBytes:     sk.TXBytes,
					})
				}
				continue
			}

			// Loopback connection into Dropbear: inspect peer socket owner
			caller, hasCaller := localClientBySport[sk.PeerPort]
			if hasCaller {
				switch caller.ProcName {
				case "ssh-ws":
					// Already recorded from ssh-ws API, just link PID if needed
					if wsInfo, ok := wsPortToClient[sk.PeerPort]; ok && wsInfo.Username != "" && sk.PID > 0 {
						// Associate PID outbound sockets with ssh-ws session
						for idx := range sessions {
							if sessions[idx].SubProtocol == "ssh_ws" && sessions[idx].Username == wsInfo.Username && sessions[idx].PID == 0 {
								sessions[idx].PID = sk.PID
								break
							}
						}
					}
				case "dnstt-server":
					if uname != "" && (len(validUsers) == 0 || validUsers[uname]) {
						sessions = append(sessions, rawSSHSession{
							Username:    uname,
							ClientIP:    "SlowDNS-Tunnel",
							SubProtocol: "slowdns",
							Transport:   "SlowDNS Tunnel (UDP :53/:5300)",
							ServerPort:  "53/5300",
							PID:         sk.PID,
							RXBytes:     sk.RXBytes,
							TXBytes:     sk.TXBytes,
						})
					}
				case "haproxy":
					if uname != "" && (len(validUsers) == 0 || validUsers[uname]) {
						extIP := "TLS-Client"
						if haproxyCursor < len(haproxyExtClients) {
							extIP = haproxyExtClients[haproxyCursor]
							haproxyCursor++
						}
						sessions = append(sessions, rawSSHSession{
							Username:    uname,
							ClientIP:    extIP,
							SubProtocol: "ssh_ssl",
							Transport:   "Direct SSH SSL/TLS (:443/:8443)",
							ServerPort:  "443",
							PID:         sk.PID,
							RXBytes:     sk.RXBytes,
							TXBytes:     sk.TXBytes,
						})
					}
				}
			}
		}
	}

	// Step 4: Parse OpenVPN status logs (status-version 2 CLIENT_LIST + ROUTING_TABLE)
	ovpnFiles := []string{
		"/etc/openvpn/server/openvpn-status-tcp.log",
		"/etc/openvpn/server/openvpn-status-udp.log",
		"/var/log/openvpn/openvpn-status.log",
		"/etc/openvpn/openvpn-status.log",
	}
	activeVIPs := make(map[string]bool)
	for _, statusPath := range ovpnFiles {
		f, err := os.Open(statusPath)
		if err != nil {
			continue
		}
		protoLabel := "OpenVPN TCP (:1194)"
		portLabel := "1194"
		if strings.Contains(statusPath, "udp") {
			protoLabel = "OpenVPN UDP (:2200)"
			portLabel = "2200"
		}
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			line := sc.Text()
			if strings.HasPrefix(line, "CLIENT_LIST,") {
				// CLIENT_LIST,Common Name,Real Address,Virtual Address,Virtual IPv6 Address,Bytes Received,Bytes Sent,...
				cols := strings.Split(line, ",")
				if len(cols) >= 7 {
					cn := strings.TrimSpace(cols[1])
					if cn == "" || cn == "UNDEF" || (len(validUsers) > 0 && !validUsers[cn]) {
						continue
					}
					realAddr, _ := parseAddrPort(cols[2])
					vip := strings.TrimSpace(cols[3])
					rx, _ := strconv.ParseInt(strings.TrimSpace(cols[5]), 10, 64)
					tx, _ := strconv.ParseInt(strings.TrimSpace(cols[6]), 10, 64)
					if vip != "" {
						activeVIPs[vip] = true
					}
					sessions = append(sessions, rawSSHSession{
						Username:    cn,
						ClientIP:    realAddr,
						SubProtocol: "openvpn",
						Transport:   protoLabel,
						ServerPort:  portLabel,
						VirtualIP:   vip,
						RXBytes:     rx,
						TXBytes:     tx,
					})
				}
			}
		}
		_ = f.Close()
	}

	// Step 5: Inspect /proc/net/nf_conntrack for active OpenVPN Virtual IP outbound flows!
	if len(activeVIPs) > 0 {
		if cf, err := os.Open("/proc/net/nf_conntrack"); err == nil {
			sc := bufio.NewScanner(cf)
			for sc.Scan() {
				line := sc.Text()
				var srcIP, dstIP, dport string
				for _, tok := range strings.Fields(line) {
					if srcIP == "" && strings.HasPrefix(tok, "src=") {
						srcIP = tok[4:]
					} else if dstIP == "" && strings.HasPrefix(tok, "dst=") {
						dstIP = tok[4:]
					} else if dport == "" && strings.HasPrefix(tok, "dport=") {
						dport = tok[6:]
					}
				}
				if activeVIPs[srcIP] && dstIP != "" && !strings.HasPrefix(dstIP, "10.") && dstIP != "127.0.0.1" {
					vipOutboundDests[srcIP] = append(vipOutboundDests[srcIP], net.JoinHostPort(dstIP, dport))
				}
			}
			_ = cf.Close()
		}
	}

	return sessions, pidOutboundDests, vipOutboundDests
}

// BatchQueryXrayStats queries ALL non-zero Xray user traffic counters in a single `xray api statsquery` call!
func (s *monitorService) BatchQueryXrayStats(ctx context.Context) map[string]int64 {
	res := make(map[string]int64)
	if s.config == nil || s.config.XrayBinary == "" {
		return res
	}
	if _, err := os.Stat(s.config.XrayBinary); err != nil {
		return res
	}

	cmdCtx, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()

	out, err := exec.CommandContext(cmdCtx, s.config.XrayBinary, "api", "statsquery",
		"--server="+s.config.XrayAPIAddress, "-pattern", "user>>>").Output()
	if err != nil || len(out) == 0 {
		return res
	}

	var parsed struct {
		Stat []struct {
			Name  string      `json:"name"`
			Value interface{} `json:"value"`
		} `json:"stat"`
	}
	if json.Unmarshal(out, &parsed) == nil {
		for _, item := range parsed.Stat {
			// user>>>USERNAME>>>traffic>>>uplink
			parts := strings.Split(item.Name, ">>>")
			if len(parts) < 4 || parts[0] != "user" {
				continue
			}
			var val int64
			switch v := item.Value.(type) {
			case float64:
				val = int64(v)
			case string:
				val, _ = strconv.ParseInt(v, 10, 64)
			}
			if val > 0 {
				res[parts[1]] += val
			}
		}
	}
	return res
}

type xrayUserLogTelemetry struct {
	IPs        map[string]bool
	Transports map[string]bool
	Domains    map[string]int
	ProtoByDom map[string]string
	LastSeen   map[string]string
}

func (s *monitorService) parseXrayAccessLogTelemetry(windowSec int) map[string]*xrayUserLogTelemetry {
	out := make(map[string]*xrayUserLogTelemetry)
	if s.config == nil || s.config.XrayAccessLog == "" {
		return out
	}

	f, err := os.Open(s.config.XrayAccessLog)
	if err != nil {
		return out
	}
	defer f.Close()

	// Tail-seek last 512KB so even multi-hundred-MB logs parse in < 2ms!
	if st, err := f.Stat(); err == nil && st.Size() > 524288 {
		_, _ = f.Seek(st.Size()-524288, io.SeekStart)
	}

	now := time.Now()
	cutoff := now.Add(-time.Duration(windowSec) * time.Second)
	loc := now.Location()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if !strings.Contains(line, "accepted") {
			continue
		}
		m := reXrayLogLine.FindStringSubmatch(line)
		if len(m) < 7 {
			continue
		}

		ts, err := time.ParseInLocation("2006/01/02 15:04:05", m[1], loc)
		if err != nil || ts.Before(cutoff) {
			continue
		}

		clientIP := strings.TrimPrefix(strings.TrimSuffix(m[2], "]"), "[")
		clientIP = strings.TrimPrefix(clientIP, "::ffff:")
		netProto := m[3]
		destAddr := m[4]
		inboundTag := strings.TrimSpace(m[5])
		username := strings.TrimSpace(m[6])

		destHost := destAddr
		if h, _, err := net.SplitHostPort(destAddr); err == nil && h != "" {
			destHost = h
		}
		destHost = strings.ToLower(strings.TrimSuffix(destHost, "."))

		ut := out[username]
		if ut == nil {
			ut = &xrayUserLogTelemetry{
				IPs:        make(map[string]bool, 4),
				Transports: make(map[string]bool, 4),
				Domains:    make(map[string]int, 16),
				ProtoByDom: make(map[string]string, 16),
				LastSeen:   make(map[string]string, 16),
			}
			out[username] = ut
		}

		if clientIP != "" && clientIP != "127.0.0.1" && clientIP != "::1" {
			ut.IPs[clientIP] = true
		} else if clientIP != "" && len(ut.IPs) == 0 {
			ut.IPs[clientIP] = true
		}

		if inboundTag != "" {
			// Handle "vless-ws -> direct" style tags cleanly
			primaryTag := strings.TrimSpace(strings.SplitN(inboundTag, "->", 2)[0])
			primaryTag = strings.TrimSpace(strings.SplitN(primaryTag, ">>", 2)[0])
			if primaryTag != "" {
				ut.Transports[primaryTag] = true
			}
		}

		if destHost != "" && destHost != "127.0.0.1" && destHost != "localhost" {
			ut.Domains[destHost]++
			ut.ProtoByDom[destHost] = netProto
			ut.LastSeen[destHost] = m[1]
		}
	}

	return out
}

func (s *monitorService) parseNoobzSessions() (map[string][]string, map[string]int64) {
	devicesByUser := make(map[string][]string)
	bytesByUser := make(map[string]int64)

	data, err := os.ReadFile("/etc/noobzvpns/db_user.json")
	if err != nil {
		return devicesByUser, bytesByUser
	}

	var dbUser struct {
		Users map[string]struct {
			Statistic struct {
				BytesUsage struct {
					Up   int64 `json:"up"`
					Down int64 `json:"down"`
				} `json:"bytes_usage"`
				ActiveDevices []string `json:"active_devices"`
			} `json:"statistic"`
		} `json:"users"`
	}
	if err := json.Unmarshal(data, &dbUser); err != nil {
		return devicesByUser, bytesByUser
	}

	for u, val := range dbUser.Users {
		if len(val.Statistic.ActiveDevices) > 0 {
			devicesByUser[u] = val.Statistic.ActiveDevices
		}
		bytesByUser[u] = val.Statistic.BytesUsage.Up + val.Statistic.BytesUsage.Down
	}
	return devicesByUser, bytesByUser
}

// GetMonitorEntries returns live session monitor entries for a protocol, enriched with Apps/Domains, Protocol/Transport, ISP & GeoIP!
func (s *monitorService) GetMonitorEntries(ctx context.Context, protocol string) ([]model.MonitorEntry, error) {
	if protocol == "all" || protocol == "" {
		uni, err := s.GetUnifiedMonitor(ctx)
		if err != nil {
			return nil, err
		}
		var flat []model.MonitorEntry
		for _, p := range []string{"ssh", "vless", "vmess", "trojan", "noobz"} {
			flat = append(flat, uni.Protocols[p]...)
		}
		return flat, nil
	}

	cacheKey := "monitor:proto:" + protocol
	val, err := s.snap.GetOrLoad(cacheKey, 1500*time.Millisecond, func() (interface{}, error) {
		return s.computeProtocolMonitor(ctx, protocol)
	})
	if err != nil {
		return nil, err
	}
	return val.([]model.MonitorEntry), nil
}

func (s *monitorService) computeProtocolMonitor(ctx context.Context, protocol string) ([]model.MonitorEntry, error) {
	accounts, err := s.repo.ListAllByProtocol(ctx, protocol)
	if err != nil {
		return nil, fmt.Errorf("list accounts: %w", err)
	}

	switch protocol {
	case "ssh":
		return s.computeSSHMonitor(ctx, accounts)
	case "noobz":
		return s.computeNoobzMonitor(ctx, accounts)
	case "vless", "vmess", "trojan":
		return s.computeXrayMonitor(ctx, protocol, accounts)
	default:
		return nil, model.ErrInvalidProtocol
	}
}

func (s *monitorService) computeSSHMonitor(ctx context.Context, accounts []*model.Account) ([]model.MonitorEntry, error) {
	validUsers := make(map[string]bool, len(accounts))
	for _, a := range accounts {
		validUsers[a.Username] = true
	}

	rawSessions, pidDests, vipDests := s.collectLiveSSHSessions(ctx, validUsers)
	sshProtoMap, _, _ := s.repo.GetAllSSHProtoUsage(ctx)
	dnsMap := LoadDNSCacheMap(s.config.DNSLogFile)

	// Group live sessions by username and gather public client IPs for batch GeoIP lookup
	byUser := make(map[string][]rawSSHSession)
	var allClientIPs []string
	for _, rs := range rawSessions {
		byUser[rs.Username] = append(byUser[rs.Username], rs)
		if net.ParseIP(rs.ClientIP) != nil {
			allClientIPs = append(allClientIPs, rs.ClientIP)
		}
	}
	geoMap := s.geo.LookupBatch(ctx, allClientIPs)

	entries := make([]model.MonitorEntry, 0)
	for _, acc := range accounts {
		userSess := byUser[acc.Username]
		if len(userSess) == 0 {
			continue
		}

		ipSet := make(map[string]bool)
		subProtoSet := make(map[string]bool)
		transportSet := make(map[string]bool)
		ispSet := make(map[string]bool)
		domHits := make(map[string]int)

		var ips []string
		var locations []model.GeoLocation
		var sessionDetails []model.ClientSessionDetail
		var liveBytesSum int64

		for _, us := range userSess {
			liveBytesSum += us.RXBytes + us.TXBytes
			subProtoSet[us.SubProtocol] = true
			transportSet[us.Transport] = true

			var geoPtr *model.GeoLocation
			ispStr := ""
			locStr := ""
			if g, ok := geoMap[us.ClientIP]; ok {
				gCopy := g
				geoPtr = &gCopy
				ispStr = g.ISP
				if g.City != "" && g.Country != "" {
					locStr = g.City + ", " + g.Country
				} else {
					locStr = g.Country
				}
			}

			if us.ClientIP != "" && !ipSet[us.ClientIP] {
				ipSet[us.ClientIP] = true
				ips = append(ips, us.ClientIP)
				if geoPtr != nil {
					locations = append(locations, *geoPtr)
					if ispStr != "" && !ispSet[ispStr] {
						ispSet[ispStr] = true
					}
				}
			}

			// Collect outbound destinations from SSH/Dropbear PID or OpenVPN VIP
			if us.PID > 0 {
				for _, dst := range pidDests[us.PID] {
					host, _, _ := net.SplitHostPort(dst)
					if dom, ok := dnsMap[host]; ok {
						domHits[dom]++
					} else if host != "" {
						domHits[host]++
					}
				}
			}
			if us.VirtualIP != "" {
				for _, dst := range vipDests[us.VirtualIP] {
					host, _, _ := net.SplitHostPort(dst)
					if dom, ok := dnsMap[host]; ok {
						domHits[dom]++
					} else if host != "" {
						domHits[host]++
					}
				}
			}

			sessionDetails = append(sessionDetails, model.ClientSessionDetail{
				ClientIP:    us.ClientIP,
				Protocol:    "ssh",
				SubProtocol: us.SubProtocol,
				Transport:   us.Transport,
				ServerPort:  us.ServerPort,
				VirtualIP:   us.VirtualIP,
				PID:         us.PID,
				RXBytes:     us.RXBytes,
				TXBytes:     us.TXBytes,
				TotalBytes:  us.RXBytes + us.TXBytes,
				ISP:         ispStr,
				Location:    locStr,
				Geo:         geoPtr,
			})
		}

		// Merge persisted SSH All-Protocol breakdown with live bytes if higher
		bd, hasBD := sshProtoMap[acc.Username]
		if !hasBD {
			bd, _ = s.repo.GetSSHProtoUsage(ctx, acc.Username)
		}
		usedBytes := acc.UsedBytes
		if bd.Total > usedBytes {
			usedBytes = bd.Total
		}
		if liveBytesSum > usedBytes {
			usedBytes = liveBytesSum
		}

		apps, domains, activities := summarizeAppActivities(domHits, nil, nil)
		remBytes, pct := calcQuotaProgress(usedBytes, acc.QuotaBytes)

		entries = append(entries, model.MonitorEntry{
			Protocol:        "ssh",
			Username:        acc.Username,
			Status:          acc.Status,
			IPCount:         len(ips),
			IPLimit:         acc.LimitIP,
			IPs:             ips,
			ActiveProtocols: sortedKeys(subProtoSet),
			Transports:      sortedKeys(transportSet),
			ISPs:            sortedKeys(ispSet),
			Locations:       locations,
			AccessedApps:    apps,
			AccessedDomains: domains,
			AppActivities:   activities,
			Sessions:        sessionDetails,
			UsedBytes:       usedBytes,
			UsedHuman:       repository.FormatBytes(usedBytes),
			QuotaBytes:      acc.QuotaBytes,
			QuotaHuman:      formatQuotaHuman(acc.QuotaBytes),
			RemainingBytes:  remBytes,
			UsagePercent:    pct,
			SSHBreakdown:    &bd,
			ExpiredAt:       acc.ExpiredAt,
		})
	}

	return entries, nil
}

func (s *monitorService) computeXrayMonitor(ctx context.Context, protocol string, accounts []*model.Account) ([]model.MonitorEntry, error) {
	logTelemetry := s.parseXrayAccessLogTelemetry(180)
	liveXrayBytes := s.BatchQueryXrayStats(ctx)

	var allIPs []string
	for _, acc := range accounts {
		if ut := logTelemetry[acc.Username]; ut != nil {
			for ip := range ut.IPs {
				allIPs = append(allIPs, ip)
			}
		}
	}
	geoMap := s.geo.LookupBatch(ctx, allIPs)

	entries := make([]model.MonitorEntry, 0)
	for _, acc := range accounts {
		ut := logTelemetry[acc.Username]
		if ut == nil || len(ut.IPs) == 0 {
			continue
		}

		ips := sortedKeys(ut.IPs)
		transports := sortedKeys(ut.Transports)
		if len(transports) == 0 {
			transports = []string{protocol}
		}

		ispSet := make(map[string]bool)
		var locations []model.GeoLocation
		var sessions []model.ClientSessionDetail
		for _, ip := range ips {
			var geoPtr *model.GeoLocation
			ispStr := ""
			locStr := ""
			if g, ok := geoMap[ip]; ok {
				gCopy := g
				geoPtr = &gCopy
				locations = append(locations, gCopy)
				ispStr = g.ISP
				if ispStr != "" {
					ispSet[ispStr] = true
				}
				if g.City != "" && g.Country != "" {
					locStr = g.City + ", " + g.Country
				} else {
					locStr = g.Country
				}
			}
			sessions = append(sessions, model.ClientSessionDetail{
				ClientIP:    ip,
				Protocol:    protocol,
				SubProtocol: strings.Join(transports, ", "),
				Transport:   describeXrayTransport(transports[0]),
				ISP:         ispStr,
				Location:    locStr,
				Geo:         geoPtr,
			})
		}

		usedBytes := acc.UsedBytes + liveXrayBytes[acc.Username]
		remBytes, pct := calcQuotaProgress(usedBytes, acc.QuotaBytes)
		apps, domains, activities := summarizeAppActivities(ut.Domains, ut.ProtoByDom, ut.LastSeen)

		entries = append(entries, model.MonitorEntry{
			Protocol:        protocol,
			Username:        acc.Username,
			Status:          acc.Status,
			IPCount:         len(ips),
			IPLimit:         acc.LimitIP,
			IPs:             ips,
			ActiveProtocols: []string{protocol},
			Transports:      transports,
			ISPs:            sortedKeys(ispSet),
			Locations:       locations,
			AccessedApps:    apps,
			AccessedDomains: domains,
			AppActivities:   activities,
			Sessions:        sessions,
			UsedBytes:       usedBytes,
			UsedHuman:       repository.FormatBytes(usedBytes),
			QuotaBytes:      acc.QuotaBytes,
			QuotaHuman:      formatQuotaHuman(acc.QuotaBytes),
			RemainingBytes:  remBytes,
			UsagePercent:    pct,
			ExpiredAt:       acc.ExpiredAt,
		})
	}

	return entries, nil
}

func (s *monitorService) computeNoobzMonitor(ctx context.Context, accounts []*model.Account) ([]model.MonitorEntry, error) {
	devsByUser, bytesByUser := s.parseNoobzSessions()

	var candidateIPs []string
	for _, devs := range devsByUser {
		for _, d := range devs {
			ip := strings.Split(d, ":")[0]
			if net.ParseIP(ip) != nil {
				candidateIPs = append(candidateIPs, ip)
			}
		}
	}
	geoMap := s.geo.LookupBatch(ctx, candidateIPs)

	entries := make([]model.MonitorEntry, 0)
	for _, acc := range accounts {
		devs := devsByUser[acc.Username]
		if len(devs) == 0 {
			continue
		}

		var ips []string
		ispSet := make(map[string]bool)
		var locations []model.GeoLocation
		seenIP := make(map[string]bool)
		for _, d := range devs {
			ip := strings.Split(d, ":")[0]
			if net.ParseIP(ip) != nil && !seenIP[ip] {
				seenIP[ip] = true
				ips = append(ips, ip)
				if g, ok := geoMap[ip]; ok {
					locations = append(locations, g)
					if g.ISP != "" {
						ispSet[g.ISP] = true
					}
				}
			}
		}

		usedBytes := acc.UsedBytes
		if b := bytesByUser[acc.Username]; b > usedBytes {
			usedBytes = b
		}
		remBytes, pct := calcQuotaProgress(usedBytes, acc.QuotaBytes)

		entries = append(entries, model.MonitorEntry{
			Protocol:        "noobz",
			Username:        acc.Username,
			Status:          acc.Status,
			IPCount:         len(devs),
			IPLimit:         acc.LimitIP,
			IPs:             ips,
			Devices:         devs,
			ActiveProtocols: []string{"noobz"},
			Transports:      []string{"NoobzVPN TCP/WS (:8585/:80/:443)"},
			ISPs:            sortedKeys(ispSet),
			Locations:       locations,
			UsedBytes:       usedBytes,
			UsedHuman:       repository.FormatBytes(usedBytes),
			QuotaBytes:      acc.QuotaBytes,
			QuotaHuman:      formatQuotaHuman(acc.QuotaBytes),
			RemainingBytes:  remBytes,
			UsagePercent:    pct,
			ExpiredAt:       acc.ExpiredAt,
		})
	}
	return entries, nil
}

// GetUnifiedMonitor aggregates live sessions across ALL 5 protocols in a single coalesced snapshot.
func (s *monitorService) GetUnifiedMonitor(ctx context.Context) (*model.UnifiedMonitorReport, error) {
	val, err := s.snap.GetOrLoad("monitor:unified", 1500*time.Millisecond, func() (interface{}, error) {
		protocols := []string{"ssh", "vless", "vmess", "trojan", "noobz"}
		rep := &model.UnifiedMonitorReport{
			Timestamp:       time.Now(),
			ByProtocolCount: make(map[string]int, len(protocols)),
			Protocols:       make(map[string][]model.MonitorEntry, len(protocols)),
		}

		appFreq := make(map[string]int)
		for _, p := range protocols {
			entries, err := s.GetMonitorEntries(ctx, p)
			if err != nil {
				rep.Protocols[p] = []model.MonitorEntry{}
				continue
			}
			if entries == nil {
				entries = []model.MonitorEntry{}
			}
			rep.Protocols[p] = entries
			rep.ByProtocolCount[p] = len(entries)
			rep.TotalOnlineUsers += len(entries)
			for _, e := range entries {
				rep.TotalConnections += e.IPCount
				for _, app := range e.AccessedApps {
					appFreq[app]++
				}
			}
		}

		type kv struct {
			k string
			v int
		}
		var ranked []kv
		for k, v := range appFreq {
			ranked = append(ranked, kv{k, v})
		}
		sort.Slice(ranked, func(i, j int) bool {
			if ranked[i].v == ranked[j].v {
				return ranked[i].k < ranked[j].k
			}
			return ranked[i].v > ranked[j].v
		})
		for i := 0; i < len(ranked) && i < 15; i++ {
			rep.TopApps = append(rep.TopApps, ranked[i].k)
		}

		return rep, nil
	})
	if err != nil {
		return nil, err
	}
	return val.(*model.UnifiedMonitorReport), nil
}

// GetUserActivity returns deep live session, app/domain, protocol, ISP & GeoIP telemetry for a single user.
func (s *monitorService) GetUserActivity(ctx context.Context, protocol, username string) (*model.MonitorEntry, error) {
	acc, err := s.repo.GetByUsername(ctx, protocol, username)
	if err != nil {
		return nil, err
	}
	if acc == nil {
		return nil, model.ErrAccountNotFound
	}

	entries, err := s.GetMonitorEntries(ctx, protocol)
	if err == nil {
		for i := range entries {
			if entries[i].Username == username {
				return &entries[i], nil
			}
		}
	}

	// User exists in DB even if currently offline: return full quota & status envelope with 0 active IPs
	used := acc.UsedBytes
	var sshBD *model.SSHProtoUsageBreakdown
	if protocol == "ssh" {
		bd, _ := s.repo.GetSSHProtoUsage(ctx, username)
		if bd.Total > used {
			used = bd.Total
		}
		sshBD = &bd
	} else if protocol == "vless" || protocol == "vmess" || protocol == "trojan" {
		live := s.BatchQueryXrayStats(ctx)
		used += live[username]
	}
	rem, pct := calcQuotaProgress(used, acc.QuotaBytes)

	return &model.MonitorEntry{
		Protocol:        protocol,
		Username:        acc.Username,
		Status:          acc.Status,
		IPCount:         0,
		IPLimit:         acc.LimitIP,
		IPs:             []string{},
		AccessedApps:    []string{},
		AccessedDomains: []string{},
		UsedBytes:       used,
		UsedHuman:       repository.FormatBytes(used),
		QuotaBytes:      acc.QuotaBytes,
		QuotaHuman:      formatQuotaHuman(acc.QuotaBytes),
		RemainingBytes:  rem,
		UsagePercent:    pct,
		SSHBreakdown:    sshBD,
		ExpiredAt:       acc.ExpiredAt,
	}, nil
}

// LookupUserAutoDetect automatically detects which protocol(s) a username belongs to (SSH/OpenSSH/Dropbear/SSH-SSL/SSH-WS/SlowDNS/OpenVPN,
// VLESS, VMess, Trojan, NoobzVPN) and returns complete login state, connected IPs, ISPs, GeoIP locations, accessed apps/domains,
// all-protocol quota usage, account metadata, and connection configuration links in one response.
func (s *monitorService) LookupUserAutoDetect(ctx context.Context, username string, xraySvc XrayService) (*model.UserAutoDetectReport, error) {
	accounts, err := s.repo.GetByUsernameAllProtocols(ctx, username)
	if err != nil {
		return nil, err
	}

	unified, _ := s.GetUnifiedMonitor(ctx)
	liveByProto := make(map[string]model.MonitorEntry)
	if unified != nil {
		for proto, list := range unified.Protocols {
			for _, entry := range list {
				if entry.Username == username {
					liveByProto[proto] = entry
					break
				}
			}
		}
	}

	if len(accounts) == 0 && len(liveByProto) == 0 {
		return nil, model.ErrAccountNotFound
	}

	domain := ""
	if s.config != nil {
		domain = s.config.Domain()
	}

	report := &model.UserAutoDetectReport{
		Username:          username,
		DetectedProtocols: []string{},
		ActiveProtocols:   []string{},
		ActiveTransports:  []string{},
		ConnectedIPs:      []string{},
		ISPs:              []string{},
		Locations:         []model.GeoLocation{},
		AccessedApps:      []string{},
		AccessedDomains:   []string{},
		AppActivities:     []model.AppActivity{},
		Sessions:          []model.ClientSessionDetail{},
		Accounts:          []model.UserProtocolAccountDetail{},
		CheckedAt:         time.Now(),
	}

	seenActiveProto := make(map[string]bool)
	seenTransport := make(map[string]bool)
	seenIP := make(map[string]bool)
	seenISP := make(map[string]bool)
	seenGeoIP := make(map[string]bool)
	seenApp := make(map[string]bool)
	seenDomain := make(map[string]bool)
	actByDom := make(map[string]model.AppActivity)

	var totalQuotaBytes, totalUsedBytes int64
	var sshBreakdownPtr *model.SSHProtoUsageBreakdown

	mergeMonitor := func(mon *model.MonitorEntry) {
		if mon == nil {
			return
		}
		for _, ap := range mon.ActiveProtocols {
			if ap != "" && !seenActiveProto[ap] {
				seenActiveProto[ap] = true
				report.ActiveProtocols = append(report.ActiveProtocols, ap)
			}
		}
		for _, tr := range mon.Transports {
			if tr != "" && !seenTransport[tr] {
				seenTransport[tr] = true
				report.ActiveTransports = append(report.ActiveTransports, tr)
			}
		}
		for _, ip := range mon.IPs {
			if ip != "" && !seenIP[ip] {
				seenIP[ip] = true
				report.ConnectedIPs = append(report.ConnectedIPs, ip)
			}
		}
		for _, isp := range mon.ISPs {
			if isp != "" && !seenISP[isp] {
				seenISP[isp] = true
				report.ISPs = append(report.ISPs, isp)
			}
		}
		for _, loc := range mon.Locations {
			if loc.IP != "" && !seenGeoIP[loc.IP] {
				seenGeoIP[loc.IP] = true
				report.Locations = append(report.Locations, loc)
			}
		}
		for _, app := range mon.AccessedApps {
			if app != "" && !seenApp[app] {
				seenApp[app] = true
				report.AccessedApps = append(report.AccessedApps, app)
			}
		}
		for _, dom := range mon.AccessedDomains {
			if dom != "" && !seenDomain[dom] {
				seenDomain[dom] = true
				report.AccessedDomains = append(report.AccessedDomains, dom)
			}
		}
		for _, act := range mon.AppActivities {
			if prev, exists := actByDom[act.Domain]; exists {
				prev.Hits += act.Hits
				actByDom[act.Domain] = prev
			} else {
				actByDom[act.Domain] = act
			}
		}
		report.Sessions = append(report.Sessions, mon.Sessions...)
	}

	now := time.Now()
	for _, acc := range accounts {
		report.DetectedProtocols = append(report.DetectedProtocols, acc.Protocol)

		var monPtr *model.MonitorEntry
		isOnline := false
		if live, ok := liveByProto[acc.Protocol]; ok && live.IPCount > 0 {
			liveCopy := live
			monPtr = &liveCopy
			isOnline = true
		} else if fullMon, err := s.GetUserActivity(ctx, acc.Protocol, username); err == nil && fullMon != nil {
			monPtr = fullMon
			isOnline = fullMon.IPCount > 0
		}

		accCopy := *acc
		if monPtr != nil && monPtr.UsedBytes > accCopy.UsedBytes {
			accCopy.UsedBytes = monPtr.UsedBytes
		}
		if acc.Protocol == "ssh" && monPtr != nil && monPtr.SSHBreakdown != nil {
			bdCopy := *monPtr.SSHBreakdown
			sshBreakdownPtr = &bdCopy
		}

		totalQuotaBytes += accCopy.QuotaBytes
		totalUsedBytes += accCopy.UsedBytes
		if accCopy.LimitIP > report.IPLimit {
			report.IPLimit = accCopy.LimitIP
		}

		if isOnline {
			report.Online = true
			if report.PrimaryProtocol == "" {
				report.PrimaryProtocol = acc.Protocol
			}
			mergeMonitor(monPtr)
		}

		if report.AccountStatus == "" || (report.AccountStatus != "active" && accCopy.Status == "active" && !accCopy.IsExpired()) {
			if accCopy.Status == "active" && accCopy.IsExpired() {
				report.AccountStatus = "expired"
			} else {
				report.AccountStatus = accCopy.Status
			}
		}

		daysRem := 0
		if remHours := accCopy.ExpiredAt.Sub(now).Hours(); remHours > 0 {
			daysRem = int((remHours + 23.999) / 24.0)
		}

		var cfgLink *model.ConfigLink
		if xraySvc != nil {
			if link, err := xraySvc.GetConfigLink(ctx, accCopy.Protocol, accCopy.Username, accCopy.Secret, domain); err == nil {
				cfgLink = link
			}
		}

		connIPs := []string{}
		activeSubs := []string{}
		transports := []string{}
		activeIPCnt := 0
		if monPtr != nil {
			if monPtr.IPs != nil {
				connIPs = monPtr.IPs
			}
			activeIPCnt = monPtr.IPCount
			activeSubs = monPtr.ActiveProtocols
			transports = monPtr.Transports
		}

		report.Accounts = append(report.Accounts, model.UserProtocolAccountDetail{
			Protocol:           accCopy.Protocol,
			Online:             isOnline,
			Status:             accCopy.Status,
			DaysRemaining:      daysRem,
			ActiveIPCount:      activeIPCnt,
			IPLimit:            accCopy.LimitIP,
			ConnectedIPs:       connIPs,
			ActiveSubProtocols: activeSubs,
			Transports:         transports,
			Account:            &accCopy,
			Config:             cfgLink,
			LiveMonitor:        monPtr,
		})
	}

	// Also surface any live session whose OS/Xray user wasn't in SQLite yet
	if len(accounts) == 0 {
		for _, proto := range []string{"ssh", "vless", "vmess", "trojan", "noobz"} {
			if live, ok := liveByProto[proto]; ok {
				liveCopy := live
				report.Online = report.Online || liveCopy.IPCount > 0
				report.DetectedProtocols = append(report.DetectedProtocols, proto)
				if report.PrimaryProtocol == "" {
					report.PrimaryProtocol = proto
				}
				if report.AccountStatus == "" {
					report.AccountStatus = "active"
				}
				totalUsedBytes += liveCopy.UsedBytes
				totalQuotaBytes += liveCopy.QuotaBytes
				if proto == "ssh" && liveCopy.SSHBreakdown != nil {
					bdCopy := *liveCopy.SSHBreakdown
					sshBreakdownPtr = &bdCopy
				}
				mergeMonitor(&liveCopy)
			}
		}
	}

	if report.PrimaryProtocol == "" && len(report.DetectedProtocols) > 0 {
		report.PrimaryProtocol = report.DetectedProtocols[0]
	}

	for _, act := range actByDom {
		report.AppActivities = append(report.AppActivities, act)
	}
	sort.Slice(report.AppActivities, func(i, j int) bool {
		if report.AppActivities[i].Hits == report.AppActivities[j].Hits {
			return report.AppActivities[i].Domain < report.AppActivities[j].Domain
		}
		return report.AppActivities[i].Hits > report.AppActivities[j].Hits
	})

	report.TotalActiveIPs = len(report.ConnectedIPs)
	remBytes, pct := calcQuotaProgress(totalUsedBytes, totalQuotaBytes)
	remHuman := "Unlimited"
	if totalQuotaBytes > 0 {
		remHuman = repository.FormatBytes(remBytes)
	}
	report.QuotaSummary = model.UserQuotaOverview{
		QuotaBytes:     totalQuotaBytes,
		QuotaHuman:     formatQuotaHuman(totalQuotaBytes),
		UsedBytes:      totalUsedBytes,
		UsedHuman:      repository.FormatBytes(totalUsedBytes),
		RemainingBytes: remBytes,
		RemainingHuman: remHuman,
		UsagePercent:   pct,
		SSHBreakdown:   sshBreakdownPtr,
	}

	return report, nil
}

// GetSSHAllProtocolQuota returns server-wide and per-user SSH quota across OpenSSH, Dropbear, SSH SSL/TLS, SSH-WS, SlowDNS, and OpenVPN!
func (s *monitorService) GetSSHAllProtocolQuota(ctx context.Context) (*model.SSHQuotaSummaryReport, error) {
	val, err := s.snap.GetOrLoad("quota:ssh:all", 1500*time.Millisecond, func() (interface{}, error) {
		accounts, err := s.repo.ListAllByProtocol(ctx, "ssh")
		if err != nil {
			return nil, err
		}

		byUserBD, serverBD, _ := s.repo.GetAllSSHProtoUsage(ctx)
		validUsers := make(map[string]bool, len(accounts))
		for _, a := range accounts {
			validUsers[a.Username] = true
		}
		liveSessions, _, _ := s.collectLiveSSHSessions(ctx, validUsers)

		liveIPs := make(map[string]map[string]bool)
		liveProtos := make(map[string]map[string]bool)
		for _, ls := range liveSessions {
			if liveIPs[ls.Username] == nil {
				liveIPs[ls.Username] = make(map[string]bool)
				liveProtos[ls.Username] = make(map[string]bool)
			}
			if ls.ClientIP != "" {
				liveIPs[ls.Username][ls.ClientIP] = true
			}
			liveProtos[ls.Username][ls.SubProtocol] = true
		}

		rep := &model.SSHQuotaSummaryReport{
			TotalAccounts:   len(accounts),
			ServerBreakdown: serverBD,
			Users:           make([]model.SSHUserQuotaDetail, 0, len(accounts)),
		}

		for _, acc := range accounts {
			if acc.Status == "active" {
				rep.ActiveAccounts++
			} else if acc.Status == "suspended" {
				rep.SuspendedAccounts++
			}
			bd, ok := byUserBD[acc.Username]
			if !ok {
				bd, _ = s.repo.GetSSHProtoUsage(ctx, acc.Username)
			}
			used := acc.UsedBytes
			if bd.Total > used {
				used = bd.Total
			}
			rem, pct := calcQuotaProgress(used, acc.QuotaBytes)
			actIPs := len(liveIPs[acc.Username])
			if actIPs > 0 {
				rep.OnlineUsers++
			}
			rep.Users = append(rep.Users, model.SSHUserQuotaDetail{
				Username:        acc.Username,
				Status:          acc.Status,
				QuotaBytes:      acc.QuotaBytes,
				QuotaHuman:      formatQuotaHuman(acc.QuotaBytes),
				UsedBytes:       used,
				UsedHuman:       repository.FormatBytes(used),
				RemainingBytes:  rem,
				RemainingHuman:  formatQuotaHuman(rem),
				UsagePercent:    pct,
				LimitIP:         acc.LimitIP,
				ActiveIPCount:   actIPs,
				ActiveProtocols: sortedKeys(liveProtos[acc.Username]),
				ExpiredAt:       acc.ExpiredAt,
				Breakdown:       bd,
			})
		}

		return rep, nil
	})
	if err != nil {
		return nil, err
	}
	return val.(*model.SSHQuotaSummaryReport), nil
}

// GetSSHUserQuota returns detailed SSH All-Protocol quota breakdown for a single SSH account.
func (s *monitorService) GetSSHUserQuota(ctx context.Context, username string) (*model.SSHUserQuotaDetail, error) {
	acc, err := s.repo.GetByUsername(ctx, "ssh", username)
	if err != nil {
		return nil, err
	}
	if acc == nil {
		return nil, model.ErrAccountNotFound
	}

	rep, err := s.GetSSHAllProtocolQuota(ctx)
	if err == nil {
		for i := range rep.Users {
			if rep.Users[i].Username == username {
				return &rep.Users[i], nil
			}
		}
	}

	bd, _ := s.repo.GetSSHProtoUsage(ctx, username)
	used := acc.UsedBytes
	if bd.Total > used {
		used = bd.Total
	}
	rem, pct := calcQuotaProgress(used, acc.QuotaBytes)

	return &model.SSHUserQuotaDetail{
		Username:        acc.Username,
		Status:          acc.Status,
		QuotaBytes:      acc.QuotaBytes,
		QuotaHuman:      formatQuotaHuman(acc.QuotaBytes),
		UsedBytes:       used,
		UsedHuman:       repository.FormatBytes(used),
		RemainingBytes:  rem,
		RemainingHuman:  formatQuotaHuman(rem),
		UsagePercent:    pct,
		LimitIP:         acc.LimitIP,
		ActiveProtocols: []string{},
		ExpiredAt:       acc.ExpiredAt,
		Breakdown:       bd,
	}, nil
}

// GetProtocolQuotaList returns quota usage across all users of any protocol.
func (s *monitorService) GetProtocolQuotaList(ctx context.Context, protocol string) ([]model.ProtocolQuotaEntry, error) {
	val, err := s.snap.GetOrLoad("quota:proto:"+protocol, 1500*time.Millisecond, func() (interface{}, error) {
		accounts, err := s.repo.ListAllByProtocol(ctx, protocol)
		if err != nil {
			return nil, err
		}

		var liveXray map[string]int64
		var sshBDMap map[string]model.SSHProtoUsageBreakdown
		var noobzBytes map[string]int64

		switch protocol {
		case "ssh":
			sshBDMap, _, _ = s.repo.GetAllSSHProtoUsage(ctx)
		case "vless", "vmess", "trojan":
			liveXray = s.BatchQueryXrayStats(ctx)
		case "noobz":
			_, noobzBytes = s.parseNoobzSessions()
		default:
			return nil, model.ErrInvalidProtocol
		}

		out := make([]model.ProtocolQuotaEntry, 0, len(accounts))
		for _, acc := range accounts {
			used := acc.UsedBytes
			var bdPtr *model.SSHProtoUsageBreakdown
			switch protocol {
			case "ssh":
				if bd, ok := sshBDMap[acc.Username]; ok {
					bdCopy := bd
					bdPtr = &bdCopy
					if bd.Total > used {
						used = bd.Total
					}
				}
			case "vless", "vmess", "trojan":
				used += liveXray[acc.Username]
			case "noobz":
				if nb := noobzBytes[acc.Username]; nb > used {
					used = nb
				}
			}
			rem, pct := calcQuotaProgress(used, acc.QuotaBytes)
			out = append(out, model.ProtocolQuotaEntry{
				Protocol:       protocol,
				Username:       acc.Username,
				Status:         acc.Status,
				QuotaBytes:     acc.QuotaBytes,
				QuotaHuman:     formatQuotaHuman(acc.QuotaBytes),
				UsedBytes:      used,
				UsedHuman:      repository.FormatBytes(used),
				RemainingBytes: rem,
				UsagePercent:   pct,
				LimitIP:        acc.LimitIP,
				ExpiredAt:      acc.ExpiredAt,
				SSHBreakdown:   bdPtr,
			})
		}
		return out, nil
	})
	if err != nil {
		return nil, err
	}
	return val.([]model.ProtocolQuotaEntry), nil
}

// GetUserQuota returns quota usage for a single user on any protocol.
func (s *monitorService) GetUserQuota(ctx context.Context, protocol, username string) (*model.ProtocolQuotaEntry, error) {
	list, err := s.GetProtocolQuotaList(ctx, protocol)
	if err != nil {
		return nil, err
	}
	for i := range list {
		if list[i].Username == username {
			return &list[i], nil
		}
	}
	return nil, model.ErrAccountNotFound
}

// Helper utilities

func summarizeAppActivities(domHits map[string]int, protoByDom, lastSeen map[string]string) ([]string, []string, []model.AppActivity) {
	if len(domHits) == 0 {
		return []string{}, []string{}, []model.AppActivity{}
	}

	type domRank struct {
		dom  string
		hits int
	}
	ranked := make([]domRank, 0, len(domHits))
	for d, h := range domHits {
		ranked = append(ranked, domRank{d, h})
	}
	sort.Slice(ranked, func(i, j int) bool {
		if ranked[i].hits == ranked[j].hits {
			return ranked[i].dom < ranked[j].dom
		}
		return ranked[i].hits > ranked[j].hits
	})

	appSet := make(map[string]bool)
	var apps []string
	var domains []string
	var activities []model.AppActivity

	limit := len(ranked)
	if limit > 20 {
		limit = 20
	}

	for i := 0; i < limit; i++ {
		d := ranked[i].dom
		app, cat := ClassifyDomainApp(d)
		if !appSet[app] {
			appSet[app] = true
			apps = append(apps, app)
		}
		domains = append(domains, d)

		act := model.AppActivity{
			App:      app,
			Category: cat,
			Domain:   d,
			Hits:     ranked[i].hits,
		}
		if protoByDom != nil {
			act.Protocol = protoByDom[d]
		}
		if lastSeen != nil {
			act.LastSeen = lastSeen[d]
		}
		activities = append(activities, act)
	}

	return apps, domains, activities
}

func calcQuotaProgress(used, quota int64) (int64, float64) {
	if quota <= 0 {
		return -1, 0
	}
	rem := quota - used
	if rem < 0 {
		rem = 0
	}
	pct := float64(used*1000/quota) / 10.0
	if pct > 100 {
		pct = 100
	}
	return rem, pct
}

func formatQuotaHuman(q int64) string {
	if q <= 0 {
		return "Unlimited"
	}
	return repository.FormatBytes(q)
}

func sortedKeys(m map[string]bool) []string {
	if len(m) == 0 {
		return []string{}
	}
	out := make([]string, 0, len(m))
	for k := range m {
		if k != "" {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out
}

func describeXrayTransport(tag string) string {
	switch {
	case strings.Contains(tag, "xhttp"):
		return "XHTTP SplitHTTP"
	case strings.Contains(tag, "hu"):
		return "HTTPUpgrade"
	case strings.Contains(tag, "grpc"):
		return "gRPC TLS"
	case strings.Contains(tag, "ws"):
		return "WebSocket"
	default:
		return tag
	}
}

func detectPrimaryLocalIP() string {
	conn, err := net.Dial("udp", "1.1.1.1:80")
	if err == nil {
		defer conn.Close()
		if ua, ok := conn.LocalAddr().(*net.UDPAddr); ok && ua.IP != nil {
			return ua.IP.String()
		}
	}
	addrs, err := net.InterfaceAddrs()
	if err == nil {
		for _, a := range addrs {
			if ipnet, ok := a.(*net.IPNet); ok && !ipnet.IP.IsLoopback() && ipnet.IP.To4() != nil {
				return ipnet.IP.String()
			}
		}
	}
	return "127.0.0.1"
}
