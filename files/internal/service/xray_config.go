package service

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/rs/zerolog"
)

// XrayClientSpec describes a client to add to Xray inbounds.
type XrayClientSpec struct {
	Username string
	Secret   string
}

// XrayConfigMutator performs thread-safe, cross-process locked, single-pass JSON mutations on /etc/xray/config.json.
// Adding 500 accounts during a Flash Sale executes 1 file read, 1 in-memory JSON pass, 1 atomic rename, and 1 Xray reload.
type XrayConfigMutator struct {
	mu       sync.Mutex
	cfg      *config.Config
	logger   *zerolog.Logger
	lockFile string
}

func isTestMode() bool {
	return os.Getenv("AUTOSCRIPT_TEST_MODE") == "1" || os.Getenv("AUTOSCRIPT_TEST_SKIP_OS_USERS") == "1"
}

// NewXrayConfigMutator creates a new XrayConfigMutator.
func NewXrayConfigMutator(cfg *config.Config, logger *zerolog.Logger) *XrayConfigMutator {
	lockPath := "/run/autoscript-xraycfg.lock"
	if isTestMode() || os.Geteuid() != 0 {
		if cfg != nil && cfg.XrayConfig != "" {
			lockPath = filepath.Join(filepath.Dir(cfg.XrayConfig), ".autoscript-xraycfg.lock")
		} else {
			lockPath = filepath.Join(os.TempDir(), "autoscript-xraycfg.lock")
		}
	} else if _, err := os.Stat("/run"); err != nil {
		lockPath = filepath.Join(os.TempDir(), "autoscript-xraycfg.lock")
	}
	return &XrayConfigMutator{
		cfg:      cfg,
		logger:   logger,
		lockFile: lockPath,
	}
}

func (m *XrayConfigMutator) acquireFlock() (*os.File, func()) {
	f, err := os.OpenFile(m.lockFile, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		// Fallback to temp dir if /run is not writable (e.g. non-root unit tests)
		alt := filepath.Join(os.TempDir(), "autoscript-xraycfg.lock")
		f, err = os.OpenFile(alt, os.O_CREATE|os.O_RDWR, 0600)
		if err != nil {
			return nil, func() {}
		}
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
	return f, func() {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		_ = f.Close()
	}
}

// AddClientsBatch adds 1..N clients to all matching protocol inbounds in a single atomic pass.
func (m *XrayConfigMutator) AddClientsBatch(ctx context.Context, protocol string, clients []XrayClientSpec) error {
	if len(clients) == 0 {
		return nil
	}
	if protocol != "vless" && protocol != "vmess" && protocol != "trojan" {
		return model.ErrInvalidProtocol
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	_, unlock := m.acquireFlock()
	defer unlock()

	rawCfg, err := os.ReadFile(m.cfg.XrayConfig)
	if err != nil {
		return fmt.Errorf("read xray config %s: %w", m.cfg.XrayConfig, err)
	}

	var root map[string]json.RawMessage
	if err := json.Unmarshal(rawCfg, &root); err != nil {
		return fmt.Errorf("parse xray config json: %w", err)
	}

	inboundsRaw, ok := root["inbounds"]
	if !ok {
		return fmt.Errorf("xray config missing 'inbounds' array")
	}

	var inbounds []map[string]json.RawMessage
	if err := json.Unmarshal(inboundsRaw, &inbounds); err != nil {
		return fmt.Errorf("parse xray inbounds: %w", err)
	}

	matchedInbounds := 0
	for idx, ib := range inbounds {
		var ibProto string
		if pRaw, ok := ib["protocol"]; ok {
			_ = json.Unmarshal(pRaw, &ibProto)
		}
		if ibProto != protocol {
			continue
		}

		settingsRaw, ok := ib["settings"]
		if !ok {
			continue
		}
		var settings map[string]json.RawMessage
		if err := json.Unmarshal(settingsRaw, &settings); err != nil {
			continue
		}
		clientsRaw, ok := settings["clients"]
		if !ok {
			continue
		}

		var existing []map[string]interface{}
		if err := json.Unmarshal(clientsRaw, &existing); err != nil {
			continue
		}

		matchedInbounds++
		existingByEmail := make(map[string]int, len(existing)+len(clients))
		for i, c := range existing {
			if em, ok := c["email"].(string); ok && em != "" {
				existingByEmail[em] = i
			}
		}

		for _, spec := range clients {
			entry := buildXrayClientObject(protocol, spec.Username, spec.Secret)
			if pos, exists := existingByEmail[spec.Username]; exists {
				existing[pos] = entry
			} else {
				existingByEmail[spec.Username] = len(existing)
				existing = append(existing, entry)
			}
		}

		updatedClients, err := json.Marshal(existing)
		if err != nil {
			return fmt.Errorf("marshal clients: %w", err)
		}
		settings["clients"] = updatedClients

		updatedSettings, err := json.Marshal(settings)
		if err != nil {
			return fmt.Errorf("marshal inbound settings: %w", err)
		}
		ib["settings"] = updatedSettings
		inbounds[idx] = ib
	}

	if matchedInbounds == 0 {
		return fmt.Errorf("no inbounds for protocol '%s' found in xray config", protocol)
	}

	updatedInbounds, err := json.Marshal(inbounds)
	if err != nil {
		return fmt.Errorf("marshal inbounds: %w", err)
	}
	root["inbounds"] = updatedInbounds

	return m.validateWriteAndReload(ctx, root)
}

// RemoveClientsBatch removes 1..N clients by email from all matching protocol inbounds in a single atomic pass.
func (m *XrayConfigMutator) RemoveClientsBatch(ctx context.Context, protocol string, usernames []string) error {
	if len(usernames) == 0 {
		return nil
	}
	if protocol != "vless" && protocol != "vmess" && protocol != "trojan" {
		return model.ErrInvalidProtocol
	}

	m.mu.Lock()
	defer m.mu.Unlock()

	_, unlock := m.acquireFlock()
	defer unlock()

	rawCfg, err := os.ReadFile(m.cfg.XrayConfig)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read xray config: %w", err)
	}

	var root map[string]json.RawMessage
	if err := json.Unmarshal(rawCfg, &root); err != nil {
		return fmt.Errorf("parse xray config: %w", err)
	}

	inboundsRaw, ok := root["inbounds"]
	if !ok {
		return nil
	}
	var inbounds []map[string]json.RawMessage
	if err := json.Unmarshal(inboundsRaw, &inbounds); err != nil {
		return nil
	}

	toRemove := make(map[string]bool, len(usernames))
	for _, u := range usernames {
		toRemove[u] = true
	}

	changed := false
	for idx, ib := range inbounds {
		var ibProto string
		if pRaw, ok := ib["protocol"]; ok {
			_ = json.Unmarshal(pRaw, &ibProto)
		}
		if ibProto != protocol {
			continue
		}

		settingsRaw, ok := ib["settings"]
		if !ok {
			continue
		}
		var settings map[string]json.RawMessage
		if err := json.Unmarshal(settingsRaw, &settings); err != nil {
			continue
		}
		clientsRaw, ok := settings["clients"]
		if !ok {
			continue
		}

		var existing []map[string]interface{}
		if err := json.Unmarshal(clientsRaw, &existing); err != nil {
			continue
		}

		filtered := make([]map[string]interface{}, 0, len(existing))
		for _, c := range existing {
			em, _ := c["email"].(string)
			if toRemove[em] {
				changed = true
				continue
			}
			filtered = append(filtered, c)
		}

		updatedClients, err := json.Marshal(filtered)
		if err != nil {
			return err
		}
		settings["clients"] = updatedClients
		updatedSettings, err := json.Marshal(settings)
		if err != nil {
			return err
		}
		ib["settings"] = updatedSettings
		inbounds[idx] = ib
	}

	if !changed {
		return nil
	}

	updatedInbounds, err := json.Marshal(inbounds)
	if err != nil {
		return err
	}
	root["inbounds"] = updatedInbounds

	return m.validateWriteAndReload(ctx, root)
}

func (m *XrayConfigMutator) validateWriteAndReload(ctx context.Context, root map[string]json.RawMessage) error {
	output, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return fmt.Errorf("serialize xray config: %w", err)
	}

	tmpFile := strings.TrimSuffix(m.cfg.XrayConfig, ".json") + ".tmp.json"
	if err := os.WriteFile(tmpFile, output, 0600); err != nil {
		return fmt.Errorf("write temp xray config: %w", err)
	}

	// Run `xray -test` if the xray binary is installed on the host
	if m.cfg.XrayBinary != "" {
		if st, err := os.Stat(m.cfg.XrayBinary); err == nil && !st.IsDir() {
			testCmd := exec.CommandContext(ctx, m.cfg.XrayBinary, "-test", "-config", tmpFile)
			if testOut, err := testCmd.CombinedOutput(); err != nil {
				_ = os.Remove(tmpFile)
				return fmt.Errorf("%w: %s", model.ErrXrayTestFailed, strings.TrimSpace(string(testOut)))
			}
		}
	}

	if err := os.Rename(tmpFile, m.cfg.XrayConfig); err != nil {
		_ = os.Remove(tmpFile)
		return fmt.Errorf("atomic replace xray config: %w", err)
	}

	// Reload Xray once if running under systemd as root in production
	if !isTestMode() && os.Geteuid() == 0 {
		if _, err := os.Stat("/run/systemd/system"); err == nil {
			reloadCmd := exec.CommandContext(ctx, "systemctl", "reload-or-restart", "xray")
			if out, err := reloadCmd.CombinedOutput(); err != nil && m.logger != nil {
				m.logger.Warn().Err(err).Str("output", strings.TrimSpace(string(out))).Msg("systemctl reload-or-restart xray warning")
			}
		}
	}

	return nil
}

func buildXrayClientObject(protocol, username, secret string) map[string]interface{} {
	switch protocol {
	case "vless":
		return map[string]interface{}{
			"id":    secret,
			"email": username,
		}
	case "vmess":
		return map[string]interface{}{
			"id":      secret,
			"alterId": 0,
			"email":   username,
		}
	case "trojan":
		return map[string]interface{}{
			"password": secret,
			"email":    username,
		}
	default:
		return map[string]interface{}{
			"id":    secret,
			"email": username,
		}
	}
}
