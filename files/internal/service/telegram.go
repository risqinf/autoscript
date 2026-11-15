package service

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/rs/zerolog"
)

// TelegramNotifier handles asynchronous, non-blocking Telegram notifications for account lifecycle events.
type TelegramNotifier struct {
	botKeyFile string
	chatIDFile string
	logger     *zerolog.Logger
	httpClient *http.Client
}

// NewTelegramNotifier creates a new TelegramNotifier reading credentials from /etc/autoscript or /etc/xray.
func NewTelegramNotifier(logger *zerolog.Logger) *TelegramNotifier {
	botFile := "/etc/autoscript/bot.key"
	if _, err := os.Stat(botFile); err != nil {
		if _, err2 := os.Stat("/etc/xray/bot.key"); err2 == nil {
			botFile = "/etc/xray/bot.key"
		}
	}

	chatFile := "/etc/autoscript/chat.id"
	if _, err := os.Stat(chatFile); err != nil {
		if _, err2 := os.Stat("/etc/xray/chat.id"); err2 == nil {
			chatFile = "/etc/xray/chat.id"
		} else if _, err3 := os.Stat("/etc/xray/client.id"); err3 == nil {
			chatFile = "/etc/xray/client.id"
		}
	}

	return &TelegramNotifier{
		botKeyFile: botFile,
		chatIDFile: chatFile,
		logger:     logger,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}
}

// getCredentials reads the bot token and chat ID dynamically from disk.
func (t *TelegramNotifier) getCredentials() (string, string) {
	tokBytes, err := os.ReadFile(t.botKeyFile)
	if err != nil || len(tokBytes) == 0 {
		return "", ""
	}
	chatBytes, err := os.ReadFile(t.chatIDFile)
	if err != nil || len(chatBytes) == 0 {
		return "", ""
	}
	return strings.TrimSpace(string(tokBytes)), strings.TrimSpace(string(chatBytes))
}

// Send sends an HTML-formatted message to Telegram asynchronously. Never blocks the caller.
func (t *TelegramNotifier) Send(text string) {
	go func() {
		token, chatID := t.getCredentials()
		if token == "" || chatID == "" {
			return
		}

		apiURL := fmt.Sprintf("https://api.telegram.org/bot%s/sendMessage", token)
		payload := map[string]interface{}{
			"chat_id":                  chatID,
			"text":                     text,
			"parse_mode":               "HTML",
			"disable_web_page_preview": true,
		}

		bodyBytes, err := json.Marshal(payload)
		if err != nil {
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		req, err := http.NewRequestWithContext(ctx, "POST", apiURL, bytes.NewBuffer(bodyBytes))
		if err != nil {
			return
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := t.httpClient.Do(req)
		if err != nil {
			if t.logger != nil {
				t.logger.Debug().Err(err).Msg("telegram send failed")
			}
			return
		}
		defer resp.Body.Close()
	}()
}

func htmlEsc(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}

// NotifyCreate sends an alert when a single VPN account is created.
func (t *TelegramNotifier) NotifyCreate(protocol, username, expiryStr string, quotaGB int64, limitIP int, actor string) {
	qStr := "Unlimited"
	if quotaGB > 0 {
		qStr = fmt.Sprintf("%d GB", quotaGB)
	}
	ipStr := "Unlimited"
	if limitIP > 0 {
		ipStr = fmt.Sprintf("%d IP", limitIP)
	}
	if actor == "" {
		actor = "API / Web"
	}

	msg := fmt.Sprintf(
		"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>    ⊹ %s ACCOUNT CREATED ⊹</b>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>Username :</b> <code>%s</code>\n"+
			"<b>Protocol :</b> <code>%s</code>\n"+
			"<b>Quota    :</b> <code>%s</code>\n"+
			"<b>Limit IP :</b> <code>%s</code>\n"+
			"<b>Expired  :</b> <code>%s</code>\n"+
			"<b>Creator  :</b> <code>%s</code>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>",
		strings.ToUpper(protocol),
		htmlEsc(username),
		strings.ToUpper(protocol),
		htmlEsc(qStr),
		htmlEsc(ipStr),
		htmlEsc(expiryStr),
		htmlEsc(actor),
	)
	t.Send(msg)
}

// NotifyBulkCreate sends an alert when bulk accounts are provisioned.
func (t *TelegramNotifier) NotifyBulkCreate(protocol string, count int, prefix, actor string) {
	if actor == "" {
		actor = "API / Flash-Sale"
	}
	msg := fmt.Sprintf(
		"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>  ⊹ FLASH-SALE BULK CREATED ⊹</b>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>Protocol :</b> <code>%s</code>\n"+
			"<b>Count    :</b> <code>%d accounts</code>\n"+
			"<b>Prefix   :</b> <code>%s</code>\n"+
			"<b>Actor    :</b> <code>%s</code>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>",
		strings.ToUpper(protocol),
		count,
		htmlEsc(prefix),
		htmlEsc(actor),
	)
	t.Send(msg)
}

// NotifyDelete sends an alert when an account is deleted.
func (t *TelegramNotifier) NotifyDelete(protocol, username, actor string) {
	if actor == "" {
		actor = "API / Admin"
	}
	msg := fmt.Sprintf(
		"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>    ⊹ %s ACCOUNT DELETED ⊹</b>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>Username :</b> <code>%s</code>\n"+
			"<b>Protocol :</b> <code>%s</code>\n"+
			"<b>Status   :</b> <b>DELETED</b>\n"+
			"<b>By       :</b> <code>%s</code>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>",
		strings.ToUpper(protocol),
		htmlEsc(username),
		strings.ToUpper(protocol),
		htmlEsc(actor),
	)
	t.Send(msg)
}

// NotifySuspend sends an alert when an account is banned/suspended (with reason).
func (t *TelegramNotifier) NotifySuspend(protocol, username, reason string) {
	reasonLabel := reason
	if reason == "iplimit" || strings.Contains(reason, "ip") {
		reasonLabel = "Limit IP Exceeded (Multi-Device Banned)"
	} else if reason == "quota" || reason == "quota_exceeded" {
		reasonLabel = "Quota Bandwidth Habis (Usage Limit Exceeded)"
	} else if reason == "expired" {
		reasonLabel = "Masa Aktif Berakhir (Expired)"
	}

	msg := fmt.Sprintf(
		"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>    ⚠️ %s ACCOUNT SUSPENDED / BANNED ⚠️</b>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>Username :</b> <code>%s</code>\n"+
			"<b>Protocol :</b> <code>%s</code>\n"+
			"<b>Status   :</b> <b>SUSPENDED / BANNED</b>\n"+
			"<b>Reason   :</b> <code>%s</code>\n"+
			"<b>Action   :</b> <i>Koneksi diputus & akun dinonaktifkan</i>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>",
		strings.ToUpper(protocol),
		htmlEsc(username),
		strings.ToUpper(protocol),
		htmlEsc(reasonLabel),
	)
	t.Send(msg)
}

// NotifyUnsuspend sends an alert when an account is unbanned / reactivated.
func (t *TelegramNotifier) NotifyUnsuspend(protocol, username, reason string, isAuto bool) {
	title := fmt.Sprintf("%s ACCOUNT UNBANNED / RECOVERED", strings.ToUpper(protocol))
	if isAuto {
		title = fmt.Sprintf("AUTO-UNBAN (15 MENIT) • %s", strings.ToUpper(protocol))
	}
	if reason == "" {
		reason = "Dipulihkan oleh Admin / API"
	}

	msg := fmt.Sprintf(
		"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>    ⊹ %s ⊹</b>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>\n"+
			"<b>Username :</b> <code>%s</code>\n"+
			"<b>Protocol :</b> <code>%s</code>\n"+
			"<b>Status   :</b> <b>ACTIVE (Dipulihkan)</b>\n"+
			"<b>Catatan  :</b> <code>%s</code>\n"+
			"<b>━━━━━━━━━━━━━━━━━━━━━━━━━━━</b>",
		title,
		htmlEsc(username),
		strings.ToUpper(protocol),
		htmlEsc(reason),
	)
	t.Send(msg)
}
