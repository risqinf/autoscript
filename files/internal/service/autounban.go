package service

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/rs/zerolog"
)

// AutoUnbanService periodically checks for suspended accounts and automatically unbans them after 15 minutes cooldown.
type AutoUnbanService struct {
	repo       repository.AccountRepository
	accountSvc AccountService
	notifier   *TelegramNotifier
	logger     *zerolog.Logger
	stopCh     chan struct{}
}

// NewAutoUnbanService creates a new AutoUnbanService.
func NewAutoUnbanService(
	repo repository.AccountRepository,
	accountSvc AccountService,
	notifier *TelegramNotifier,
	logger *zerolog.Logger,
) *AutoUnbanService {
	return &AutoUnbanService{
		repo:       repo,
		accountSvc: accountSvc,
		notifier:   notifier,
		logger:     logger,
		stopCh:     make(chan struct{}),
	}
}

// Start launches the 15-minute auto-unban background evaluation loop.
func (s *AutoUnbanService) Start() {
	go func() {
		ticker := time.NewTicker(45 * time.Second)
		defer ticker.Stop()

		for {
			select {
			case <-s.stopCh:
				return
			case <-ticker.C:
				s.evaluateSuspendedAccounts()
			}
		}
	}()
}

// Stop terminates the auto-unban loop.
func (s *AutoUnbanService) Stop() {
	close(s.stopCh)
}

func (s *AutoUnbanService) evaluateSuspendedAccounts() {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()

	accounts, err := s.repo.ListAllSuspended(ctx)
	if err != nil {
		if s.logger != nil {
			s.logger.Debug().Err(err).Msg("auto-unban: failed to list suspended accounts")
		}
		return
	}

	now := time.Now()
	for _, acc := range accounts {
		if acc == nil || acc.Status != "suspended" {
			continue
		}

		// Account must not be expired
		if acc.ExpiredAt.Before(now) {
			continue
		}

		// Check cooldown duration: 15 minutes (900 seconds)
		suspendedDuration := now.Sub(acc.UpdatedAt)
		if suspendedDuration < 15*time.Minute {
			continue
		}

		reason := acc.Note
		isQuota := strings.Contains(strings.ToLower(reason), "quota")

		var unbanErr error
		if isQuota {
			// If suspended due to quota, reset used bytes and reactivate
			_, unbanErr = s.accountSvc.ResetAccountQuota(ctx, acc.Protocol, acc.Username)
		} else {
			// For IP Limit or other temporary bans, unsuspend and restore configuration
			_, unbanErr = s.accountSvc.UnsuspendAccount(ctx, acc.Protocol, acc.Username)
		}

		if unbanErr != nil {
			if s.logger != nil {
				s.logger.Error().Err(unbanErr).
					Str("protocol", acc.Protocol).
					Str("username", acc.Username).
					Msg("auto-unban: failed to reactivate account")
			}
			continue
		}

		// Audit log entry
		_ = s.repo.WriteAuditLog(ctx, "system", "auto_unban", acc.Protocol, acc.Username,
			fmt.Sprintf("auto-unbanned after %v cooldown (reason was: %s)", suspendedDuration.Round(time.Second), reason))

		if s.logger != nil {
			s.logger.Info().
				Str("protocol", acc.Protocol).
				Str("username", acc.Username).
				Str("reason", reason).
				Msg("account automatically unbanned after 15 minutes cooldown")
		}

		// Send Telegram Notification
		if s.notifier != nil {
			reasonDesc := "Limit IP Multi-Device (Masa jeda 15 menit selesai)"
			if isQuota {
				reasonDesc = "Batas Kuota Bandwidth (Reset otomatis setelah jeda 15 menit)"
			}
			s.notifier.NotifyUnsuspend(acc.Protocol, acc.Username, reasonDesc, true)
		}
	}
}
