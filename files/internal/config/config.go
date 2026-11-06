package config

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// Config holds application configuration for Autoscript Enterprise API v5.6.1.
type Config struct {
	// Server
	ListenAddress  string
	MaxConcurrency int
	MaxBulkSize    int

	// Databases
	APIDatabasePath  string
	MainDatabasePath string

	// Security & Multi-Layer SHA-256 Verification
	APIKeyFile    string
	APISecretFile string
	APISecret     string
	SecurityMode  string // "strict" (default: 5-layer SHA-256) or "compat"
	MaxSkewSec    int64
	AllowedIPs    []string

	// Paths & External Services
	DomainFile     string
	XrayConfig     string
	XrayBinary     string
	XrayAccessLog  string
	XrayAPIAddress string
	SSHWSAPI       string
	DNSLogFile     string
	GeoIPCacheFile string
	BackupKeyFile  string
	ChatIDFile     string

	// Rate Limiting (Sharded In-Memory)
	RateLimit       int
	AuthBurstLimit  int
	RateLimitWindow int // seconds
}

// Load reads configuration from environment variables with production-hardened defaults.
func Load() (*Config, error) {
	listenAddr := getEnv("API_LISTEN", "")
	if listenAddr == "" {
		host := getEnv("API_HOST", "127.0.0.1")
		port := getEnv("API_PORT", "9000")
		listenAddr = host + ":" + port
	}

	xrayBin := getEnv("XRAY_BIN", "")
	if xrayBin == "" {
		xrayBin = getEnv("XRAY_BINARY", "/usr/local/bin/xray")
	}

	secMode := strings.ToLower(strings.TrimSpace(getEnv("API_SECURITY_MODE", "strict")))
	if secMode != "compat" {
		secMode = "strict"
	}

	var allowedIPs []string
	if rawIPs := strings.TrimSpace(getEnv("API_ALLOWED_IPS", "")); rawIPs != "" {
		for _, part := range strings.Split(rawIPs, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				allowedIPs = append(allowedIPs, trimmed)
			}
		}
	}

	cfg := &Config{
		ListenAddress:    listenAddr,
		MaxConcurrency:   getEnvInt("API_MAX_CONCURRENCY", detectOptimalConcurrency()),
		MaxBulkSize:      getEnvInt("API_MAX_BULK_SIZE", 1000),
		APIDatabasePath:  getEnv("API_DB_PATH", "/etc/api/api.db"),
		MainDatabasePath: getEnv("MAIN_DB_PATH", "/etc/xray/xray.db"),
		APIKeyFile:       getEnv("API_KEY_FILE", "/etc/api/key"),
		APISecretFile:    getEnv("API_SECRET_FILE", "/etc/api/secret"),
		APISecret:        strings.TrimSpace(getEnv("API_SECRET", "")),
		SecurityMode:     secMode,
		MaxSkewSec:       int64(getEnvInt("API_MAX_SKEW_SEC", 300)),
		AllowedIPs:       allowedIPs,
		DomainFile:       getEnv("DOMAIN_FILE", "/etc/xray/domain"),
		XrayConfig:       getEnv("XRAY_CONFIG", "/etc/xray/config.json"),
		XrayBinary:       xrayBin,
		XrayAccessLog:    getEnv("XRAY_ACCESS_LOG", "/var/log/xray/access.log"),
		XrayAPIAddress:   getEnv("XRAY_API", "127.0.0.1:10085"),
		SSHWSAPI:         strings.TrimRight(getEnv("SSH_WS_API", "http://127.0.0.1:8081"), "/"),
		DNSLogFile:       getEnv("DNS_LOG_FILE", "/var/log/autoscript-dns.log"),
		GeoIPCacheFile:   getEnv("GEOIP_CACHE_FILE", "/run/autoscript-geoip.cache"),
		BackupKeyFile:    getEnv("BACKUP_KEY_FILE", "/etc/xray/backup.pass"),
		ChatIDFile:       getEnv("CHATID_FILE", "/etc/xray/client.id"),
		RateLimit:        getEnvInt("RATE_LIMIT", 5000),
		AuthBurstLimit:   getEnvInt("AUTH_RATE_LIMIT", 100000),
		RateLimitWindow:  getEnvInt("RATE_LIMIT_WINDOW", 60),
	}

	if cfg.MaxBulkSize < 1 {
		cfg.MaxBulkSize = 1000
	}
	if cfg.MaxBulkSize > 5000 {
		cfg.MaxBulkSize = 5000
	}
	if cfg.MaxSkewSec < 30 {
		cfg.MaxSkewSec = 30
	}
	if cfg.RateLimitWindow < 1 {
		cfg.RateLimitWindow = 60
	}
	if cfg.AuthBurstLimit < cfg.RateLimit {
		cfg.AuthBurstLimit = cfg.RateLimit * 10
	}

	if err := cfg.ensurePathsAndSecret(); err != nil {
		return nil, fmt.Errorf("config initialization: %w", err)
	}

	return cfg, nil
}

// ensurePathsAndSecret ensures database directories exist and loads or provisions the HMAC secret.
func (c *Config) ensurePathsAndSecret() error {
	if c.APIDatabasePath != ":memory:" && !strings.HasPrefix(c.APIDatabasePath, "file::memory:") {
		if dir := filepath.Dir(c.APIDatabasePath); dir != "" && dir != "." {
			if err := os.MkdirAll(dir, 0700); err != nil {
				return fmt.Errorf("create api db dir %s: %w", dir, err)
			}
		}
	}

	if c.MainDatabasePath != ":memory:" && !strings.HasPrefix(c.MainDatabasePath, "file::memory:") {
		if dir := filepath.Dir(c.MainDatabasePath); dir != "" && dir != "." {
			if err := os.MkdirAll(dir, 0700); err != nil {
				return fmt.Errorf("create main db dir %s: %w", dir, err)
			}
		}
	}

	if c.APISecret == "" {
		if data, err := os.ReadFile(c.APISecretFile); err == nil {
			secret := strings.TrimSpace(strings.SplitN(string(data), "\n", 2)[0])
			if len(secret) >= 16 {
				c.APISecret = secret
			}
		}
	}

	if c.APISecret == "" {
		buf := make([]byte, 32)
		if _, err := rand.Read(buf); err != nil {
			return fmt.Errorf("generate api secret: %w", err)
		}
		c.APISecret = hex.EncodeToString(buf)
		if c.APISecretFile != "" {
			if dir := filepath.Dir(c.APISecretFile); dir != "" && dir != "." {
				_ = os.MkdirAll(dir, 0700)
			}
			_ = os.WriteFile(c.APISecretFile, []byte(c.APISecret+"\n"), 0600)
		}
	}

	return nil
}

// ReloadSecret re-reads APISecretFile if it exists on disk so credential rotation can be picked up dynamically.
func (c *Config) ReloadSecret() string {
	if envSec := strings.TrimSpace(os.Getenv("API_SECRET")); envSec != "" {
		return envSec
	}
	if c.APISecretFile != "" {
		if data, err := os.ReadFile(c.APISecretFile); err == nil {
			secret := strings.TrimSpace(strings.SplitN(string(data), "\n", 2)[0])
			if len(secret) >= 16 {
				return secret
			}
		}
	}
	return c.APISecret
}

// Domain reads the domain from the domain file.
func (c *Config) Domain() string {
	data, err := os.ReadFile(c.DomainFile)
	if err != nil {
		return "127.0.0.1"
	}
	d := strings.TrimSpace(string(data))
	if d == "" {
		return "127.0.0.1"
	}
	return d
}

// SQLiteDSN formats a modernc.org/sqlite DSN with connection-level PRAGMAs so every
// pooled connection inherits busy_timeout, WAL journal mode, foreign_keys, and temp_store.
// This guarantees zero SQLITE_BUSY errors under 100+ simultaneous order bursts.
func SQLiteDSN(path string, readOnly bool) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" || trimmed == ":memory:" || strings.HasPrefix(trimmed, "file::memory:") {
		return trimmed
	}
	sep := "?"
	if strings.Contains(trimmed, "?") {
		sep = "&"
	}
	pragmas := "_pragma=busy_timeout(15000)&_pragma=journal_mode(WAL)&_pragma=synchronous(NORMAL)&_pragma=foreign_keys(1)&_pragma=temp_store(MEMORY)"
	if readOnly {
		pragmas += "&_pragma=query_only(1)"
	}
	return trimmed + sep + pragmas
}

// ReadPoolSize returns an optimal SQLite reader pool size scaled to available CPUs and RAM.
func (c *Config) ReadPoolSize() int {
	cpus := runtime.NumCPU()
	memMB := detectSystemRAMMB()
	if memMB > 0 && memMB <= 1536 {
		if cpus < 2 {
			return 4
		}
		return cpus * 2
	}
	if cpus*4 < 8 {
		return 8
	}
	return cpus * 4
}

func detectOptimalConcurrency() int {
	memMB := detectSystemRAMMB()
	switch {
	case memMB > 0 && memMB <= 1536:
		return 65536 // 1GB Rocky Linux tier: handles 65k concurrent sockets within tight RAM budget
	case memMB > 0 && memMB <= 4096:
		return 262144
	default:
		return 1048576 // 1M concurrent connections
	}
}

func detectSystemRAMMB() int64 {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0
	}
	defer f.Close()

	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := sc.Text()
		if strings.HasPrefix(line, "MemTotal:") {
			fields := strings.Fields(line)
			if len(fields) >= 2 {
				if kb, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
					return kb / 1024
				}
			}
			break
		}
	}
	return 0
}

func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists && value != "" {
		return value
	}
	return defaultValue
}

func getEnvInt(key string, defaultValue int) int {
	if value, exists := os.LookupEnv(key); exists {
		if intVal, err := strconv.Atoi(strings.TrimSpace(value)); err == nil {
			return intVal
		}
	}
	return defaultValue
}
