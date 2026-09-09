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
	if domain == "" || domain == "localhost" {
		d := s.config.Domain()
		if d != "" && d != "not set" {
			domain = d
		}
	}

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

// getVLESSLink generates VLESS links and all supported transports.
func (s *xrayService) getVLESSLink(username, secret, domain string) *model.ConfigLink {
	wsTLS := fmt.Sprintf("vless://%s@%s:443?path=/vless&security=tls&encryption=none&type=ws&host=%s&sni=%s#%s-WS-TLS",
		secret, domain, domain, domain, username)
	wsNTLS := fmt.Sprintf("vless://%s@%s:80?path=/vless&encryption=none&type=ws&host=%s#%s-WS-NTLS",
		secret, domain, domain, username)
	huTLS := fmt.Sprintf("vless://%s@%s:443?path=/vless-hu&security=tls&encryption=none&type=httpupgrade&host=%s&sni=%s#%s-HU-TLS",
		secret, domain, domain, domain, username)
	huNTLS := fmt.Sprintf("vless://%s@%s:80?path=/vless-hu&encryption=none&type=httpupgrade&host=%s#%s-HU-NTLS",
		secret, domain, domain, username)
	xhttpTLS := fmt.Sprintf("vless://%s@%s:443?mode=auto&path=/vless-xhttp&security=tls&encryption=none&type=xhttp&host=%s&sni=%s#%s-XHTTP-TLS",
		secret, domain, domain, domain, username)
	xhttpNTLS := fmt.Sprintf("vless://%s@%s:80?mode=auto&path=/vless-xhttp&security=none&encryption=none&type=xhttp&host=%s#%s-XHTTP-NTLS",
		secret, domain, domain, username)
	grpcTLS := fmt.Sprintf("vless://%s@%s:443?serviceName=vless-grpc&security=tls&encryption=none&type=grpc&sni=%s#%s-gRPC",
		secret, domain, domain, username)

	return &model.ConfigLink{
		Protocol: "vless",
		Username: username,
		Link:     wsTLS,
		Remark:   wsNTLS,
		Transports: map[string]string{
			"ws_tls":     wsTLS,
			"ws_ntls":    wsNTLS,
			"hu_tls":     huTLS,
			"hu_ntls":    huNTLS,
			"xhttp_tls":  xhttpTLS,
			"xhttp_ntls": xhttpNTLS,
			"grpc_tls":   grpcTLS,
		},
	}
}

// getVMESSLink generates VMESS links and all supported transports.
func (s *xrayService) getVMESSLink(username, secret, domain string) *model.ConfigLink {
	buildVMESS := func(port, tls, net, path, suffix string) string {
		cfg := map[string]interface{}{
			"v":    "2",
			"ps":   username + suffix,
			"add":  domain,
			"port": port,
			"id":   secret,
			"aid":  "0",
			"net":  net,
			"path": path,
			"type": "none",
			"host": domain,
			"tls":  tls,
		}
		if tls == "tls" {
			cfg["sni"] = domain
		}
		b, _ := json.Marshal(cfg)
		return "vmess://" + base64.StdEncoding.EncodeToString(b)
	}

	wsTLS := buildVMESS("443", "tls", "ws", "/", "-WS-TLS")
	wsNTLS := buildVMESS("80", "none", "ws", "/", "-WS-NTLS")
	huTLS := buildVMESS("443", "tls", "httpupgrade", "/vmess-hu", "-HU-TLS")
	huNTLS := buildVMESS("80", "none", "httpupgrade", "/vmess-hu", "-HU-NTLS")
	xhttpTLS := buildVMESS("443", "tls", "xhttp", "/vmess-xhttp", "-XHTTP-TLS")
	xhttpNTLS := buildVMESS("80", "none", "xhttp", "/vmess-xhttp", "-XHTTP-NTLS")
	grpcTLS := buildVMESS("443", "tls", "grpc", "vmess-grpc", "-gRPC")

	return &model.ConfigLink{
		Protocol: "vmess",
		Username: username,
		Link:     wsTLS,
		Remark:   wsNTLS,
		Transports: map[string]string{
			"ws_tls":     wsTLS,
			"ws_ntls":    wsNTLS,
			"hu_tls":     huTLS,
			"hu_ntls":    huNTLS,
			"xhttp_tls":  xhttpTLS,
			"xhttp_ntls": xhttpNTLS,
			"grpc_tls":   grpcTLS,
		},
	}
}

// getTrojanLink generates Trojan links and all supported transports.
func (s *xrayService) getTrojanLink(username, secret, domain string) *model.ConfigLink {
	wsTLS := fmt.Sprintf("trojan://%s@%s:443?type=ws&security=tls&host=%s&path=/trojan&sni=%s#%s-WS-TLS",
		secret, domain, domain, domain, username)
	huTLS := fmt.Sprintf("trojan://%s@%s:443?type=httpupgrade&security=tls&host=%s&path=/trojan-hu&sni=%s#%s-HU-TLS",
		secret, domain, domain, domain, username)
	xhttpTLS := fmt.Sprintf("trojan://%s@%s:443?mode=auto&type=xhttp&security=tls&host=%s&path=/trojan-xhttp&sni=%s#%s-XHTTP-TLS",
		secret, domain, domain, domain, username)
	grpcTLS := fmt.Sprintf("trojan://%s@%s:443?type=grpc&security=tls&serviceName=trojan-grpc&sni=%s#%s-gRPC",
		secret, domain, domain, username)

	return &model.ConfigLink{
		Protocol: "trojan",
		Username: username,
		Link:     wsTLS,
		Remark:   huTLS,
		Transports: map[string]string{
			"ws_tls":    wsTLS,
			"hu_tls":    huTLS,
			"xhttp_tls": xhttpTLS,
			"grpc_tls":  grpcTLS,
		},
	}
}

// getSSHLink generates SSH connection info and payloads.
func (s *xrayService) getSSHLink(username, password, domain string) *model.ConfigLink {
	config := fmt.Sprintf("%s:1-65535@%s:%s", domain, username, password)

	return &model.ConfigLink{
		Protocol: "ssh",
		Username: username,
		Link:     config,
		Remark:   "HTTP Custom config",
		Transports: map[string]string{
			"payload_tls":  fmt.Sprintf("GET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]", domain),
			"payload_http": fmt.Sprintf("GET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]", domain),
		},
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
