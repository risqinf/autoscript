package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/rs/zerolog"
)

// XrayService defines the interface for xray operations.
type XrayService interface {
	GetConfigLink(ctx context.Context, protocol, username, secret, domain string) (*model.ConfigLink, error)
	GetOpenVPNConfig(ctx context.Context, username string) (string, error)
	RestartXray(ctx context.Context) error
}

// xrayService implements XrayService.
type xrayService struct {
	config *config.Config
	logger *zerolog.Logger
}

// NewXrayService creates a new XrayService.
func NewXrayService(cfg *config.Config, logger *zerolog.Logger) XrayService {
	return &xrayService{
		config: cfg,
		logger: logger,
	}
}

// GetConfigLink generates a configuration link for the given protocol.
func (s *xrayService) GetConfigLink(ctx context.Context, protocol, username, secret, domain string) (*model.ConfigLink, error) {
	switch protocol {
	case "vless":
		return s.getVLESSLink(username, secret, domain), nil
	case "vmess":
		return s.getVMESSLink(username, secret, domain), nil
	case "trojan":
		return s.getTrojanLink(username, secret, domain), nil
	case "ssh":
		return s.getSSHLink(username, secret, domain), nil
	default:
		return nil, model.ErrInvalidProtocol
	}
}

// getVLESSLink generates a VLESS link.
func (s *xrayService) getVLESSLink(username, secret, domain string) *model.ConfigLink {
	// TLS link
	tlsLink := fmt.Sprintf("vless://%s@%s:443?path=/vless&security=tls&encryption=none&type=ws&host=%s&sni=%s#%s",
		secret, domain, domain, domain, username)

	// HTTP link
	httpLink := fmt.Sprintf("vless://%s@%s:80?path=/vless&encryption=none&type=ws&host=%s#%s",
		secret, domain, domain, username)

	return &model.ConfigLink{
		Protocol: "vless",
		Username: username,
		Link:     tlsLink,
		Remark:   httpLink,
	}
}

// getVMESSLink generates a VMESS link.
func (s *xrayService) getVMESSLink(username, secret, domain string) *model.ConfigLink {
	// TLS config
	tlsConfig := map[string]interface{}{
		"v":    "2",
		"ps":   username,
		"add":  domain,
		"port": "443",
		"id":   secret,
		"aid":  "0",
		"net":  "ws",
		"path": "/",
		"type": "none",
		"host": domain,
		"tls":  "tls",
	}

	tlsJSON, _ := json.Marshal(tlsConfig)
	tlsLink := "vmess://" + base64.StdEncoding.EncodeToString(tlsJSON)

	// HTTP config
	httpConfig := map[string]interface{}{
		"v":    "2",
		"ps":   username,
		"add":  domain,
		"port": "80",
		"id":   secret,
		"aid":  "0",
		"net":  "ws",
		"path": "/",
		"type": "none",
		"host": domain,
		"tls":  "none",
	}

	httpJSON, _ := json.Marshal(httpConfig)
	httpLink := "vmess://" + base64.StdEncoding.EncodeToString(httpJSON)

	return &model.ConfigLink{
		Protocol: "vmess",
		Username: username,
		Link:     tlsLink,
		Remark:   httpLink,
	}
}

// getTrojanLink generates a Trojan link.
func (s *xrayService) getTrojanLink(username, secret, domain string) *model.ConfigLink {
	link := fmt.Sprintf("trojan://%s@%s:443?type=ws&security=tls&host=%s&path=/trojan&sni=%s#%s",
		secret, domain, domain, domain, username)

	return &model.ConfigLink{
		Protocol: "trojan",
		Username: username,
		Link:     link,
	}
}

// getSSHLink generates SSH connection info.
func (s *xrayService) getSSHLink(username, password, domain string) *model.ConfigLink {
	config := fmt.Sprintf("%s:1-65535@%s:%s", domain, username, password)

	return &model.ConfigLink{
		Protocol: "ssh",
		Username: username,
		Link:     config,
		Remark:   "HTTP Custom config",
	}
}

// GetOpenVPNConfig returns the OpenVPN TCP config file content.
func (s *xrayService) GetOpenVPNConfig(ctx context.Context, username string) (string, error) {
	configPath := "/var/www/html/risqinf/openvpn/tcp.ovpn"
	data, err := os.ReadFile(configPath)
	if err != nil {
		return "", fmt.Errorf("read ovpn config: %w", err)
	}
	return string(data), nil
}

// RestartXray restarts the xray service.
func (s *xrayService) RestartXray(ctx context.Context) error {
	cmd := exec.CommandContext(ctx, "systemctl", "restart", "xray")
	output, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("restart xray: %s: %w", strings.TrimSpace(string(output)), err)
	}
	return nil
}
