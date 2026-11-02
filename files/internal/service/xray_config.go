package service

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/rs/zerolog"
)

// XrayClientSpec describes a client to add to Xray inbounds.
type XrayClientSpec struct {
	Username string
	Secret   string
}

type xrayMutationOp struct {
	isAdd       bool
	protocol    string
	addClients  []XrayClientSpec
	removeUsers []string
	done        chan error
}

// XrayConfigMutator performs thread-safe, cross-process locked, group-committed JSON mutations on /etc/xray/config.json.
// Under simultaneous order bursts (e.g. 100+ concurrent buyers), pending Add/Remove mutations are coalesced into
// ONE single JSON read + ONE in-memory pass + ONE atomic rename + ONE debounced Xray reload.
type XrayConfigMutator struct {
	mu       sync.Mutex
	qMu      sync.Mutex
	pending  []*xrayMutationOp
	flushing bool

	reloadMu    sync.Mutex
	reloadTimer *time.Timer

	cfg      *config.Config
	logger   *zerolog.Logger
	lockFile string
}

func isTestMode() bool {
	return os.Getenv("AUTOSCRIPT_TEST_MODE") == "1" || os.Getenv("AUTOSCRIPT_TEST_SKIP_OS_USERS") == "1"
}

// NewXrayConfigMutator creates a new XrayConfigMutator with group-commit coalescing and debounced reload.
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

// AddClientsBatch adds 1..N clients to matching protocol inbounds, automatically coalescing concurrent callers.
func (m *XrayConfigMutator) AddClientsBatch(ctx context.Context, protocol string, clients []XrayClientSpec) error {
	if len(clients) == 0 {
		return nil
	}
	if protocol != "vless" && protocol != "vmess" && protocol != "trojan" {
		return model.ErrInvalidProtocol
	}

	op := &xrayMutationOp{
		isAdd:      true,
		protocol:   protocol,
		addClients: clients,
		done:       make(chan error, 1),
	}
	return m.enqueue(ctx, op)
}

// RemoveClientsBatch removes 1..N clients by email from matching protocol inbounds, coalescing concurrent callers.
func (m *XrayConfigMutator) RemoveClientsBatch(ctx context.Context, protocol string, usernames []string) error {
	if len(usernames) == 0 {
		return nil
	}
	if protocol != "vless" && protocol != "vmess" && protocol != "trojan" {
		return model.ErrInvalidProtocol
	}

	op := &xrayMutationOp{
		isAdd:       false,
		protocol:    protocol,
		removeUsers: usernames,
		done:        make(chan error, 1),
	}
	return m.enqueue(ctx, op)
}

func (m *XrayConfigMutator) enqueue(ctx context.Context, op *xrayMutationOp) error {
	m.qMu.Lock()
	m.pending = append(m.pending, op)
	startWorker := false
	if !m.flushing {
		m.flushing = true
		startWorker = true
	}
	m.qMu.Unlock()

	if startWorker {
		go m.flushLoop()
	}

	select {
	case err := <-op.done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (m *XrayConfigMutator) flushLoop() {
	for {
		// Yield briefly so simultaneous goroutines arriving in the same scheduler tick join this single disk commit.
		runtime.Gosched()

		m.qMu.Lock()
		if len(m.pending) == 0 {
			m.flushing = false
			m.qMu.Unlock()
			return
		}
		batch := m.pending
		m.pending = nil
		m.qMu.Unlock()

		perOpErrs, batchErr := m.applyCoalescedBatch(batch)
		for i, op := range batch {
			if batchErr != nil {
				op.done <- batchErr
			} else {
				op.done <- perOpErrs[i]
			}
			close(op.done)
		}
	}
}

func (m *XrayConfigMutator) applyCoalescedBatch(batch []*xrayMutationOp) ([]error, error) {
	perOpErrs := make([]error, len(batch))

	m.mu.Lock()
	defer m.mu.Unlock()

	_, unlock := m.acquireFlock()
	defer unlock()

	hasAdd := false
	for _, op := range batch {
		if op.isAdd {
			hasAdd = true
			break
		}
	}

	rawCfg, err := os.ReadFile(m.cfg.XrayConfig)
	if err != nil {
		if os.IsNotExist(err) && !hasAdd {
			return perOpErrs, nil
		}
		return nil, fmt.Errorf("read xray config %s: %w", m.cfg.XrayConfig, err)
	}

	var root map[string]json.RawMessage
	if err := json.Unmarshal(rawCfg, &root); err != nil {
		return nil, fmt.Errorf("parse xray config json: %w", err)
	}

	inboundsRaw, ok := root["inbounds"]
	if !ok {
		if !hasAdd {
			return perOpErrs, nil
		}
		return nil, fmt.Errorf("xray config missing 'inbounds' array")
	}

	var inbounds []map[string]json.RawMessage
	if err := json.Unmarshal(inboundsRaw, &inbounds); err != nil {
		if !hasAdd {
			return perOpErrs, nil
		}
		return nil, fmt.Errorf("parse xray inbounds: %w", err)
	}

	// Group operations per protocol while preserving exact arrival order within each protocol
	protoOps := map[string][]*xrayMutationOp{
		"vless":  {},
		"vmess":  {},
		"trojan": {},
	}
	for _, op := range batch {
		protoOps[op.protocol] = append(protoOps[op.protocol], op)
	}

	matchedByProto := map[string]int{}
	changed := false

	for idx, ib := range inbounds {
		var ibProto string
		if pRaw, ok := ib["protocol"]; ok {
			_ = json.Unmarshal(pRaw, &ibProto)
		}
		ops := protoOps[ibProto]
		if len(ops) == 0 {
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

		matchedByProto[ibProto]++

		// Index active clients by email for O(1) coalesced add/remove
		existingByEmail := make(map[string]int, len(existing)+len(ops)*2)
		removedIdx := make(map[int]bool)
		for i, c := range existing {
			if em, ok := c["email"].(string); ok && em != "" {
				existingByEmail[em] = i
			}
		}

		ibModified := false
		for _, op := range ops {
			if op.isAdd {
				for _, spec := range op.addClients {
					entry := buildXrayClientObject(ibProto, spec.Username, spec.Secret)
					if pos, exists := existingByEmail[spec.Username]; exists {
						delete(removedIdx, pos)
						existing[pos] = entry
					} else {
						existingByEmail[spec.Username] = len(existing)
						existing = append(existing, entry)
					}
					ibModified = true
				}
			} else {
				for _, u := range op.removeUsers {
					if pos, exists := existingByEmail[u]; exists && !removedIdx[pos] {
						removedIdx[pos] = true
						delete(existingByEmail, u)
						ibModified = true
					}
				}
			}
		}

		if !ibModified {
			continue
		}
		changed = true

		finalClients := existing
		if len(removedIdx) > 0 {
			finalClients = make([]map[string]interface{}, 0, len(existing)-len(removedIdx))
			for i, c := range existing {
				if !removedIdx[i] {
					finalClients = append(finalClients, c)
				}
			}
		}

		updatedClients, err := json.Marshal(finalClients)
		if err != nil {
			return nil, fmt.Errorf("marshal clients: %w", err)
		}
		settings["clients"] = updatedClients

		updatedSettings, err := json.Marshal(settings)
		if err != nil {
			return nil, fmt.Errorf("marshal inbound settings: %w", err)
		}
		ib["settings"] = updatedSettings
		inbounds[idx] = ib
	}

	for i, op := range batch {
		if op.isAdd && matchedByProto[op.protocol] == 0 {
			perOpErrs[i] = fmt.Errorf("no inbounds for protocol '%s' found in xray config", op.protocol)
		}
	}

	if !changed {
		return perOpErrs, nil
	}

	updatedInbounds, err := json.Marshal(inbounds)
	if err != nil {
		return nil, fmt.Errorf("marshal inbounds: %w", err)
	}
	root["inbounds"] = updatedInbounds

	if err := m.validateWriteAndReload(root); err != nil {
		return nil, err
	}
	return perOpErrs, nil
}

func (m *XrayConfigMutator) validateWriteAndReload(root map[string]json.RawMessage) error {
	output, err := json.MarshalIndent(root, "", "  ")
	if err != nil {
		return fmt.Errorf("serialize xray config: %w", err)
	}

	tmpFile := fmt.Sprintf("%s.tmp.%d.json", strings.TrimSuffix(m.cfg.XrayConfig, ".json"), os.Getpid())
	if err := os.WriteFile(tmpFile, output, 0600); err != nil {
		return fmt.Errorf("write temp xray config: %w", err)
	}

	// Run `xray -test` once for the entire coalesced batch if the xray binary is installed on the host
	if m.cfg.XrayBinary != "" {
		if st, err := os.Stat(m.cfg.XrayBinary); err == nil && !st.IsDir() {
			testCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			testCmd := exec.CommandContext(testCtx, m.cfg.XrayBinary, "-test", "-config", tmpFile)
			testOut, err := testCmd.CombinedOutput()
			cancel()
			if err != nil {
				_ = os.Remove(tmpFile)
				return fmt.Errorf("%w: %s", model.ErrXrayTestFailed, strings.TrimSpace(string(testOut)))
			}
		}
	}

	if err := os.Rename(tmpFile, m.cfg.XrayConfig); err != nil {
		_ = os.Remove(tmpFile)
		return fmt.Errorf("atomic replace xray config: %w", err)
	}

	// Debounce Xray reload (250ms window) so back-to-back order bursts never trigger systemd StartLimitBurst
	m.scheduleXrayReload()
	return nil
}

func (m *XrayConfigMutator) scheduleXrayReload() {
	if isTestMode() || os.Geteuid() != 0 {
		return
	}
	if _, err := os.Stat("/run/systemd/system"); err != nil {
		return
	}

	m.reloadMu.Lock()
	defer m.reloadMu.Unlock()

	if m.reloadTimer != nil {
		// A reload is already scheduled within the next 250ms; it will pick up this write too!
		return
	}

	m.reloadTimer = time.AfterFunc(250*time.Millisecond, func() {
		m.reloadMu.Lock()
		m.reloadTimer = nil
		m.reloadMu.Unlock()

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		reloadCmd := exec.CommandContext(ctx, "systemctl", "reload-or-restart", "xray")
		if out, err := reloadCmd.CombinedOutput(); err != nil && m.logger != nil {
			m.logger.Warn().Err(err).Str("output", strings.TrimSpace(string(out))).Msg("systemctl reload-or-restart xray warning")
		}
	})
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
