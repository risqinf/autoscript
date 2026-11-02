package service

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"syscall"
	"time"
)

type sshCreateOp struct {
	username  string
	password  string
	expiryStr string
	done      chan error
}

// ShadowMutator serializes and group-commits Linux /etc/passwd & /etc/shadow mutations
// across both concurrent API goroutines and CLI shell scripts (/run/autoscript-shadow.lock).
// Under 100+ simultaneous SSH order requests, pending user creations are coalesced under a single lock
// with a single batch `chpasswd` pipe so `useradd: cannot lock /etc/passwd` never occurs.
type ShadowMutator struct {
	mu       sync.Mutex
	qMu      sync.Mutex
	pending  []*sshCreateOp
	flushing bool
	lockFile string
}

// NewShadowMutator creates a new ShadowMutator.
func NewShadowMutator() *ShadowMutator {
	lockPath := "/run/autoscript-shadow.lock"
	if isTestMode() || os.Geteuid() != 0 {
		lockPath = filepath.Join(os.TempDir(), "autoscript-shadow.lock")
	} else if _, err := os.Stat("/run"); err != nil {
		lockPath = filepath.Join(os.TempDir(), "autoscript-shadow.lock")
	}
	return &ShadowMutator{
		lockFile: lockPath,
	}
}

func (s *ShadowMutator) acquireFlock() (*os.File, func()) {
	f, err := os.OpenFile(s.lockFile, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		alt := filepath.Join(os.TempDir(), "autoscript-shadow.lock")
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

func resolveNologinShell() string {
	for _, candidate := range []string{"/usr/sbin/nologin", "/sbin/nologin", "/bin/false"} {
		if _, err := os.Stat(candidate); err == nil {
			return candidate
		}
	}
	return "/bin/false"
}

// runChpasswdBulk pipes "user:pass\n..." to chpasswd using SHA512 (compatible with EL9, EL10, and static Dropbear 2019),
// falling back automatically to default chpasswd if `-c SHA512` is unsupported by the host shadow-utils.
func runChpasswdBulk(ctx context.Context, payload string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "chpasswd", "-c", "SHA512")
	cmd.Stdin = strings.NewReader(payload)
	out, err := cmd.CombinedOutput()
	if err == nil {
		return out, nil
	}
	fallback := exec.CommandContext(ctx, "chpasswd")
	fallback.Stdin = strings.NewReader(payload)
	return fallback.CombinedOutput()
}

// CreateUser provisions a single SSH tunnel user, automatically group-committing simultaneous arrivals.
func (s *ShadowMutator) CreateUser(ctx context.Context, username, password, expiryStr string) error {
	if skipSystemUserProvision() {
		return nil
	}

	op := &sshCreateOp{
		username:  username,
		password:  password,
		expiryStr: expiryStr,
		done:      make(chan error, 1),
	}

	s.qMu.Lock()
	s.pending = append(s.pending, op)
	startWorker := false
	if !s.flushing {
		s.flushing = true
		startWorker = true
	}
	s.qMu.Unlock()

	if startWorker {
		go s.flushCreateLoop()
	}

	select {
	case err := <-op.done:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (s *ShadowMutator) flushCreateLoop() {
	for {
		runtime.Gosched()

		s.qMu.Lock()
		if len(s.pending) == 0 {
			s.flushing = false
			s.qMu.Unlock()
			return
		}
		batch := s.pending
		s.pending = nil
		s.qMu.Unlock()

		errs := s.applyCreateBatch(batch)
		for i, op := range batch {
			op.done <- errs[i]
			close(op.done)
		}
	}
}

func (s *ShadowMutator) applyCreateBatch(batch []*sshCreateOp) []error {
	errs := make([]error, len(batch))

	s.mu.Lock()
	defer s.mu.Unlock()

	_, unlock := s.acquireFlock()
	defer unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	nologin := resolveNologinShell()
	var pwBuf strings.Builder
	var createdIdx []int

	for i, op := range batch {
		if exec.CommandContext(ctx, "id", op.username).Run() == nil {
			_ = exec.CommandContext(ctx, "usermod", "-s", nologin, "-e", op.expiryStr, "-U", op.username).Run()
		} else {
			cmd := exec.CommandContext(ctx, "useradd", "-e", op.expiryStr, "-M", "-N", "-s", nologin, op.username)
			if out, err := cmd.CombinedOutput(); err != nil {
				errs[i] = fmt.Errorf("useradd failed: %s: %w", strings.TrimSpace(string(out)), err)
				continue
			}
		}
		createdIdx = append(createdIdx, i)
		pwBuf.WriteString(op.username)
		pwBuf.WriteByte(':')
		pwBuf.WriteString(op.password)
		pwBuf.WriteByte('\n')
	}

	if len(createdIdx) > 0 {
		if out, err := runChpasswdBulk(ctx, pwBuf.String()); err != nil {
			chErr := fmt.Errorf("chpasswd failed: %s: %w", strings.TrimSpace(string(out)), err)
			for _, idx := range createdIdx {
				_ = exec.CommandContext(ctx, "userdel", "--force", batch[idx].username).Run()
				errs[idx] = chErr
			}
		}
	}

	return errs
}

// WithLock executes an arbitrary OS user/shadow operation safely under both in-process mutex and cross-process flock.
func (s *ShadowMutator) WithLock(fn func(nologin string) error) error {
	if skipSystemUserProvision() {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()

	_, unlock := s.acquireFlock()
	defer unlock()

	return fn(resolveNologinShell())
}
