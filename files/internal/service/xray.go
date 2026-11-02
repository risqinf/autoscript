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

// XrayService defines the interface for connection config link generation and Xray daemon control.
type XrayService interface {
	GetConfigLink(ctx context.Context, protocol, username, secret, domain string) (*model.ConfigLink, error)
	GetOpenVPNConfig(ctx context.Context, username string) (string, error)
	GetServerPorts() model.PortInfo
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

// GetServerPorts returns the complete multi-protocol port matrix configured on Rocky Linux 9.
func (s *xrayService) GetServerPorts() model.PortInfo {
	return model.PortInfo{
		OpenSSH:    "22, 3303",
		Dropbear:   "109, 143",
		SSHSSL:     "443, 8443",
		SSH:        "22, 3303, 109, 143",
		WSHTTP:     "80, 8080, 8880, 2052, 2082, 2086, 2095, 8888",
		WSTLS:      "443, 8443, 2053, 2083, 2087, 2096",
		BadVPN:     "7100, 7200, 7300",
		OpenVPNTCP: "1194",
		OpenVPNUDP: "2200",
		SquidProxy: "3128, 8000",
		SlowDNS:    "53, 5300 (UDP)",
		HUHTTP:     "80, 8080",
		HUTLS:      "443, 8443",
		XHTTPHTTP:  "80, 8080",
		XHTTPTLS:   "443, 8443",
		GRPCTLS:    "443, 8443",
		NoobzTCP:   "8585",
		NoobzWS:    "80, 8080 (HTTP), 443, 8443 (TLS)",
	}
}

// GetConfigLink generates all connection links, payloads, and port details for the given protocol.
func (s *xrayService) GetConfigLink(ctx context.Context, protocol, username, secret, domain string) (*model.ConfigLink, error) {
	if domain == "" || domain == "localhost" {
		d := s.config.Domain()
		if d != "" && d != "not set" {
			domain = d
		} else {
			domain = "127.0.0.1"
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
	case "noobz":
		return s.getNoobzLink(username, secret, domain), nil
	default:
		return nil, model.ErrInvalidProtocol
	}
}

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

	ports := s.GetServerPorts()
	return &model.ConfigLink{
		Protocol: "vless",
		Username: username,
		Link:     wsTLS,
		Remark:   wsNTLS,
		Ports:    &ports,
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

func (s *xrayService) getVMESSLink(username, secret, domain string) *model.ConfigLink {
	buildVMESS := func(port, tls, netType, path, suffix string) string {
		cfg := map[string]interface{}{
			"v":    "2",
			"ps":   username + suffix,
			"add":  domain,
			"port": port,
			"id":   secret,
			"aid":  "0",
			"net":  netType,
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

	ports := s.GetServerPorts()
	return &model.ConfigLink{
		Protocol: "vmess",
		Username: username,
		Link:     wsTLS,
		Remark:   wsNTLS,
		Ports:    &ports,
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

func (s *xrayService) getTrojanLink(username, secret, domain string) *model.ConfigLink {
	wsTLS := fmt.Sprintf("trojan://%s@%s:443?type=ws&security=tls&host=%s&path=/trojan&sni=%s#%s-WS-TLS",
		secret, domain, domain, domain, username)
	huTLS := fmt.Sprintf("trojan://%s@%s:443?type=httpupgrade&security=tls&host=%s&path=/trojan-hu&sni=%s#%s-HU-TLS",
		secret, domain, domain, domain, username)
	xhttpTLS := fmt.Sprintf("trojan://%s@%s:443?mode=auto&type=xhttp&security=tls&host=%s&path=/trojan-xhttp&sni=%s#%s-XHTTP-TLS",
		secret, domain, domain, domain, username)
	grpcTLS := fmt.Sprintf("trojan://%s@%s:443?type=grpc&security=tls&serviceName=trojan-grpc&sni=%s#%s-gRPC",
		secret, domain, domain, username)

	ports := s.GetServerPorts()
	return &model.ConfigLink{
		Protocol: "trojan",
		Username: username,
		Link:     wsTLS,
		Remark:   huTLS,
		Ports:    &ports,
		Transports: map[string]string{
			"ws_tls":    wsTLS,
			"hu_tls":    huTLS,
			"xhttp_tls": xhttpTLS,
			"grpc_tls":  grpcTLS,
		},
	}
}

func (s *xrayService) getSSHLink(username, password, domain string) *model.ConfigLink {
	configStr := fmt.Sprintf("%s:1-65535@%s:%s", domain, username, password)

	transports := map[string]string{
		"openssh_direct":  fmt.Sprintf("%s:22 / %s:3303", domain, domain),
		"dropbear_direct": fmt.Sprintf("%s:109 / %s:143", domain, domain),
		"ssh_ssl_tls":     fmt.Sprintf("%s:443 / %s:8443 (SNI: %s)", domain, domain, domain),
		"ssh_ws_http":     fmt.Sprintf("%s:80 / %s:8080 / %s:8888", domain, domain, domain),
		"ssh_ws_tls":      fmt.Sprintf("%s:443 / %s:8443", domain, domain),
		"openvpn_tcp_url": fmt.Sprintf("https://%s/risqinf/openvpn/tcp.ovpn", domain),
		"openvpn_udp_url": fmt.Sprintf("https://%s/risqinf/openvpn/udp.ovpn", domain),
		"payload_tls":     fmt.Sprintf("GET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]", domain),
		"payload_http":    fmt.Sprintf("GET / HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]", domain),
	}

	if nsBytes, err := os.ReadFile("/etc/slowdns/nameserver"); err == nil {
		if pubBytes, err := os.ReadFile("/etc/slowdns/server.pub"); err == nil {
			ns := strings.TrimSpace(string(nsBytes))
			pub := strings.TrimSpace(string(pubBytes))
			if ns != "" && pub != "" {
				transports["slowdns_nameserver"] = ns
				transports["slowdns_public_key"] = pub
				transports["slowdns_port"] = "53, 5300 UDP"
			}
		}
	}

	ports := s.GetServerPorts()
	return &model.ConfigLink{
		Protocol:   "ssh",
		Username:   username,
		Link:       configStr,
		Remark:     "SSH All-Protocol (OpenSSH, Dropbear, SSL/TLS, WS, SlowDNS, OpenVPN)",
		Ports:      &ports,
		Transports: transports,
	}
}

func (s *xrayService) getNoobzLink(username, password, domain string) *model.ConfigLink {
	configStr := fmt.Sprintf("%s:8585@%s:%s", domain, username, password)
	ports := s.GetServerPorts()
	return &model.ConfigLink{
		Protocol: "noobz",
		Username: username,
		Link:     configStr,
		Remark:   "NoobzVPN Payload & Identifier",
		Ports:    &ports,
		Transports: map[string]string{
			"tcp_port":   "8585",
			"ws_port":    "80, 8080 (HTTP), 443, 8443 (HTTPS)",
			"identifier": "risqinf",
			"payload":    fmt.Sprintf("GET /noobz HTTP/1.1[crlf]Host: %s[crlf]Upgrade: websocket[crlf][crlf]", domain),
		},
	}
}

// GetOpenVPNConfig returns the OpenVPN TCP config file content.
func (s *xrayService) GetOpenVPNConfig(ctx context.Context, username string) (string, error) {
	paths := []string{
		"/var/www/html/risqinf/openvpn/tcp.ovpn",
		"/etc/openvpn/tcp.ovpn",
	}
	for _, p := range paths {
		if data, err := os.ReadFile(p); err == nil {
			return string(data), nil
		}
	}
	return "", fmt.Errorf("ovpn profile not found on server")
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
