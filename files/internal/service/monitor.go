package service

import (
	"bufio"
	"context"
	"fmt"
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

// MonitorService defines the interface for monitoring operations.
type MonitorService interface {
	GetServiceStatus(ctx context.Context) ([]model.ServiceStatus, error)
	GetSystemInfo(ctx context.Context) (*model.SystemInfo, error)
	GetMonitorEntries(ctx context.Context, protocol string) ([]model.MonitorEntry, error)
}

// monitorService implements MonitorService.
type monitorService struct {
	repo   repository.AccountRepository
	config *config.Config
	logger *zerolog.Logger
}

// NewMonitorService creates a new MonitorService.
func NewMonitorService(repo repository.AccountRepository, cfg *config.Config, logger *zerolog.Logger) MonitorService {
	return &monitorService{
		repo:   repo,
		config: cfg,
		logger: logger,
	}
}

// GetServiceStatus returns the status of all services.
func (s *monitorService) GetServiceStatus(ctx context.Context) ([]model.ServiceStatus, error) {
	services := []struct {
		name string
		port string
	}{
		{"haproxy", "80, 443"},
		{"nginx", "81"},
		{"xray", "1, 2, 3"},
		{"dropbear", "109"},
		{"ssh-ws", "8888"},
		{"sshd", "22, 3303"},
		{"openvpn-server@server-tcp-1194", "1194"},
		{"vnstat", ""},
		{"rsyslog", ""},
		{"firewalld", ""},
	}

	var statuses []model.ServiceStatus
	for _, svc := range services {
		status := "inactive"
		cmd := exec.CommandContext(ctx, "systemctl", "is-active", svc.name)
		if output, err := cmd.Output(); err == nil {
			if strings.TrimSpace(string(output)) == "active" {
				status = "active"
			}
		}

		statuses = append(statuses, model.ServiceStatus{
			Name:   svc.name,
			Status: status,
			Port:   svc.port,
		})
	}

	return statuses, nil
}

// GetSystemInfo returns system information.
func (s *monitorService) GetSystemInfo(ctx context.Context) (*model.SystemInfo, error) {
	info := &model.SystemInfo{
		Domain: s.config.Domain(),
	}

	// IP
	cmd := exec.CommandContext(ctx, "hostname", "-I")
	if output, err := cmd.Output(); err == nil {
		info.IP = strings.TrimSpace(strings.Split(string(output), " ")[0])
	}

	// CPU
	cmd = exec.CommandContext(ctx, "awk", "-F:", "/model name/ {name=$2} END {print name}", "/proc/cpuinfo")
	if output, err := cmd.Output(); err == nil {
		info.CPU = strings.TrimSpace(string(output))
	}

	// Cores
	cmd = exec.CommandContext(ctx, "nproc")
	if output, err := cmd.Output(); err == nil {
		info.Cores, _ = strconv.Atoi(strings.TrimSpace(string(output)))
	}

	// RAM
	cmd = exec.CommandContext(ctx, "free", "-m")
	if output, err := cmd.Output(); err == nil {
		lines := strings.Split(string(output), "\n")
		if len(lines) >= 2 {
			fields := strings.Fields(lines[1])
			if len(fields) >= 3 {
				info.RAMTotal = fields[1] + " MB"
				info.RAMUsed = fields[2] + " MB"
			}
		}
	}

	// Swap
	cmd = exec.CommandContext(ctx, "free", "-m")
	if output, err := cmd.Output(); err == nil {
		lines := strings.Split(string(output), "\n")
		if len(lines) >= 3 {
			fields := strings.Fields(lines[2])
			if len(fields) >= 3 {
				info.SwapTotal = fields[1] + " MB"
				info.SwapUsed = fields[2] + " MB"
			}
		}
	}

	// Uptime
	cmd = exec.CommandContext(ctx, "uptime", "-p")
	if output, err := cmd.Output(); err == nil {
		info.Uptime = strings.TrimSpace(strings.TrimPrefix(string(output), "up "))
	}

	// OS
	cmd = exec.CommandContext(ctx, "sh", "-c", ". /etc/os-release && echo $PRETTY_NAME")
	if output, err := cmd.Output(); err == nil {
		info.OS = strings.TrimSpace(string(output))
	}

	return info, nil
}

// GetMonitorEntries returns login monitor entries for a protocol.
func (s *monitorService) GetMonitorEntries(ctx context.Context, protocol string) ([]model.MonitorEntry, error) {
	// Get active accounts
	accounts, _, err := s.repo.List(ctx, protocol, 1, 1000)
	if err != nil {
		return nil, fmt.Errorf("list accounts: %w", err)
	}

	// Parse access log
	logPath := "/var/log/xray/access.log"
	ipsByUser, err := s.parseAccessLog(logPath, 180) // 3 minute window
	if err != nil {
		s.logger.Warn().Err(err).Msg("failed to parse access log")
	}

	var entries []model.MonitorEntry
	for _, account := range accounts {
		ips := ipsByUser[account.Username]
		if len(ips) == 0 {
			continue // Skip users with no active connections
		}

		entry := model.MonitorEntry{
			Username:   account.Username,
			IPCount:    len(ips),
			IPLimit:    account.LimitIP,
			IPs:        ips,
			UsedBytes:  account.UsedBytes,
			QuotaBytes: account.QuotaBytes,
			ExpiredAt:  account.ExpiredAt,
		}

		entries = append(entries, entry)
	}

	return entries, nil
}

// parseAccessLog parses the xray access log and returns IPs by user.
func (s *monitorService) parseAccessLog(logPath string, windowSec int) (map[string][]string, error) {
	file, err := os.Open(logPath)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	cutoff := time.Now().Add(-time.Duration(windowSec) * time.Second)
	ipsByUser := make(map[string]map[string]bool)

	// Regex to parse log line
	// Format: 2026/07/12 10:30:00.123456 from 103.x.x.x:0 accepted tcp:host:port [tag] email: user
	re := regexp.MustCompile(`^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}).*from (\d+\.\d+\.\d+\.\d+):\d+.*email: (\S+)$`)

	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.Contains(line, "accepted") {
			continue
		}

		matches := re.FindStringSubmatch(line)
		if len(matches) < 4 {
			continue
		}

		// Parse timestamp
		tsStr := matches[1]
		ts, err := time.Parse("2006/01/02 15:04:05", tsStr)
		if err != nil {
			continue
		}

		if ts.Before(cutoff) {
			continue
		}

		ip := matches[2]
		username := matches[3]

		if ipsByUser[username] == nil {
			ipsByUser[username] = make(map[string]bool)
		}
		ipsByUser[username][ip] = true
	}

	// Convert map[string]bool to []string
	result := make(map[string][]string)
	for user, ipMap := range ipsByUser {
		for ip := range ipMap {
			result[user] = append(result[user], ip)
		}
	}

	return result, nil
}
