package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config holds application configuration.
type Config struct {
	// Server
	ListenAddress string

	// Database
	APIDatabasePath  string
	MainDatabasePath string

	// Paths
	DomainFile    string
	XrayConfig    string
	XrayBinary    string
	BackupKeyFile string
	ChatIDFile    string

	// Rate limiting
	RateLimit       int
	RateLimitWindow int // seconds

	// Xray API
	XrayAPIAddress string
}

// Load reads configuration from environment variables with defaults.
func Load() (*Config, error) {
	cfg := &Config{
		ListenAddress:    getEnv("API_LISTEN", "127.0.0.1:9000"),
		APIDatabasePath:  getEnv("API_DB_PATH", "/etc/api/api.db"),
		MainDatabasePath: getEnv("MAIN_DB_PATH", "/etc/xray/xray.db"),
		DomainFile:       getEnv("DOMAIN_FILE", "/etc/xray/domain"),
		XrayConfig:       getEnv("XRAY_CONFIG", "/etc/xray/config.json"),
		XrayBinary:       getEnv("XRAY_BINARY", "/usr/local/bin/xray"),
		BackupKeyFile:    getEnv("BACKUP_KEY_FILE", "/etc/xray/backup.pass"),
		ChatIDFile:       getEnv("CHATID_FILE", "/etc/xray/client.id"),
		RateLimit:        getEnvInt("RATE_LIMIT", 100),
		RateLimitWindow:  getEnvInt("RATE_LIMIT_WINDOW", 60),
		XrayAPIAddress:   getEnv("XRAY_API", "127.0.0.1:10085"),
	}

	if err := cfg.validate(); err != nil {
		return nil, fmt.Errorf("config validation: %w", err)
	}

	return cfg, nil
}

// validate checks that required paths exist.
func (c *Config) validate() error {
	if _, err := os.Stat(c.MainDatabasePath); os.IsNotExist(err) {
		return fmt.Errorf("main database not found: %s", c.MainDatabasePath)
	}
	return nil
}

// Domain reads the domain from the domain file.
func (c *Config) Domain() string {
	data, err := os.ReadFile(c.DomainFile)
	if err != nil {
		return "not set"
	}
	return strings.TrimSpace(string(data))
}

// getEnv gets an environment variable with a default value.
func getEnv(key, defaultValue string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return defaultValue
}

// getEnvInt gets an integer environment variable with a default value.
func getEnvInt(key string, defaultValue int) int {
	if value, exists := os.LookupEnv(key); exists {
		if intVal, err := strconv.Atoi(value); err == nil {
			return intVal
		}
	}
	return defaultValue
}
