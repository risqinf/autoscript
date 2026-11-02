package security

import (
	"context"
	"database/sql"
	"fmt"
	"net"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	_ "modernc.org/sqlite"
)

func setupTestVerifier(t testing.TB, allowedIPs []string) (*Verifier, string, string) {
	t.Helper()
	tmpDir := t.TempDir()
	apiDBPath := filepath.Join(tmpDir, "api.db")
	mainDBPath := filepath.Join(tmpDir, "xray.db")
	keyFile := filepath.Join(tmpDir, "key")
	secFile := filepath.Join(tmpDir, "secret")

	db, err := sql.Open("sqlite", apiDBPath)
	if err != nil {
		t.Fatalf("open sqlite: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })

	repo := repository.NewAPIRepositoryImpl(db)
	if err := repo.InitSchema(); err != nil {
		t.Fatalf("init schema: %v", err)
	}

	token, err := repo.CreateToken(context.Background(), "test-panel")
	if err != nil {
		t.Fatalf("create token: %v", err)
	}

	secret := "9f8e7d6c5b4a3928172635445566778899aabbccddeeff001122334455667788"
	cfg := &config.Config{
		APIDatabasePath:  apiDBPath,
		MainDatabasePath: mainDBPath,
		APIKeyFile:       keyFile,
		APISecretFile:    secFile,
		APISecret:        secret,
		SecurityMode:     "strict",
		MaxSkewSec:       300,
		AllowedIPs:       allowedIPs,
	}

	v := NewVerifier(repo, cfg)
	t.Cleanup(func() { v.Close() })
	return v, token, secret
}

func TestFiveLayerSHA256Verification(t *testing.T) {
	v, token, secret := setupTestVerifier(t, []string{"203.0.113.0/24"})

	body := []byte(`{"username":"alice_01","quota":50,"limit_ip":2,"days":30}`)
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := "nonce_abcdef1234567890"
	bodySHA, sig := SignRequest("POST", "/api/accounts/vless", "b=2&a=1", token, secret, ts, nonce, body)

	// 1. Valid 5-layer signed request (note query passed in reverse order `a=1&b=2` must still match canonicalization!)
	res, authErr := v.VerifyRequest(
		"203.0.113.10",
		"POST",
		"/api/accounts/vless",
		"a=1&b=2",
		"Bearer "+token,
		bodySHA,
		ts,
		nonce,
		sig,
		body,
	)
	if authErr != nil {
		t.Fatalf("expected valid 5-layer verification, got error: %+v", authErr)
	}
	if len(res.VerifiedLayers) != 6 {
		t.Fatalf("expected 6 verified layers (0..5), got %v", res.VerifiedLayers)
	}

	// 2. Layer 4 Anti-Replay: exact same request replayed must fail with REPLAY_DETECTED
	_, replayErr := v.VerifyRequest(
		"203.0.113.10",
		"POST",
		"/api/accounts/vless",
		"a=1&b=2",
		"Bearer "+token,
		bodySHA,
		ts,
		nonce,
		sig,
		body,
	)
	if replayErr == nil || replayErr.ErrType != model.ErrReplayDetected {
		t.Fatalf("expected REPLAY_DETECTED, got %+v", replayErr)
	}

	// 3. Layer 0 IP Policy: IP outside 203.0.113.0/24 must fail with FORBIDDEN_IP
	nonce2 := "nonce_ipcheck_1234567890"
	bodySHA2, sig2 := SignRequest("POST", "/api/accounts/vless", "", token, secret, ts, nonce2, body)
	_, ipErr := v.VerifyRequest("198.51.100.99", "POST", "/api/accounts/vless", "", "Bearer "+token, bodySHA2, ts, nonce2, sig2, body)
	if ipErr == nil || ipErr.ErrType != model.ErrForbiddenIP {
		t.Fatalf("expected FORBIDDEN_IP, got %+v", ipErr)
	}

	// 4. Layer 1 Wrong Bearer Token
	_, tokErr := v.VerifyRequest("203.0.113.10", "POST", "/api/accounts/vless", "", "Bearer wrongtoken123", bodySHA2, ts, nonce2, sig2, body)
	if tokErr == nil || tokErr.ErrType != model.ErrUnauthorized {
		t.Fatalf("expected UNAUTHORIZED, got %+v", tokErr)
	}

	// 5. Layer 2 Body Tampering (X-Content-SHA256 mismatch)
	tamperedBody := []byte(`{"username":"alice_01","quota":9999,"limit_ip":2,"days":30}`)
	_, hashErr := v.VerifyRequest("203.0.113.10", "POST", "/api/accounts/vless", "", "Bearer "+token, bodySHA2, ts, nonce2, sig2, tamperedBody)
	if hashErr == nil || hashErr.ErrType != model.ErrInvalidContentHash {
		t.Fatalf("expected INVALID_CONTENT_HASH, got %+v", hashErr)
	}

	// 6. Layer 3 Expired Timestamp
	oldTS := strconv.FormatInt(time.Now().Unix()-1000, 10)
	_, oldSig := SignRequest("POST", "/api/accounts/vless", "", token, secret, oldTS, nonce2, body)
	_, tsErr := v.VerifyRequest("203.0.113.10", "POST", "/api/accounts/vless", "", "Bearer "+token, bodySHA2, oldTS, nonce2, oldSig, body)
	if tsErr == nil || tsErr.ErrType != model.ErrTimestampExpired {
		t.Fatalf("expected TIMESTAMP_EXPIRED, got %+v", tsErr)
	}

	// 7. Layer 5 Tampered Signature must NOT burn nonce2!
	badSig := strings.Repeat("a", 64)
	_, sigErr := v.VerifyRequest("203.0.113.10", "POST", "/api/accounts/vless", "", "Bearer "+token, bodySHA2, ts, nonce2, badSig, body)
	if sigErr == nil || sigErr.ErrType != model.ErrInvalidSignature {
		t.Fatalf("expected INVALID_SIGNATURE, got %+v", sigErr)
	}

	// Verify nonce2 is STILL usable with the real signature because forged signature did not poison the cache!
	_, okAfterForge := v.VerifyRequest("203.0.113.10", "POST", "/api/accounts/vless", "", "Bearer "+token, bodySHA2, ts, nonce2, sig2, body)
	if okAfterForge != nil {
		t.Fatalf("expected nonce2 to remain unburned after forged signature attempt, got %+v", okAfterForge)
	}

	// 8. Mutual Server Response Signing
	reqID := v.NextRequestID()
	respBody := []byte(`{"success":true,"code":200}`)
	respSHA, srvSig := v.SignResponse(reqID, ts, respBody)
	if !VerifyServerResponse(secret, reqID, ts, respSHA, srvSig, respBody) {
		t.Fatal("mutual server response signature verification failed")
	}
	if VerifyServerResponse(secret, reqID, ts, respSHA, srvSig, []byte(`{"tampered":true}`)) {
		t.Fatal("expected tampered server response body to fail verification")
	}
}

func TestSpoofedXRealIPIgnoredFromExternalPeer(t *testing.T) {
	extPeer := net.ParseIP("198.51.100.77")
	got := ExtractClientIP(extPeer, "127.0.0.1", "10.0.0.1")
	if got != "198.51.100.77" {
		t.Fatalf("expected external peer IP 198.51.100.77, got %s", got)
	}

	loopback := net.ParseIP("127.0.0.1")
	gotProxied := ExtractClientIP(loopback, "203.0.113.55", "")
	if gotProxied != "203.0.113.55" {
		t.Fatalf("expected loopback proxy X-Real-IP 203.0.113.55, got %s", gotProxied)
	}
}

func TestOpenSSLBashInteroperability(t *testing.T) {
	if _, err := exec.LookPath("openssl"); err != nil {
		t.Skip("openssl not installed")
	}
	v, token, secret := setupTestVerifier(t, nil)

	ts := strconv.FormatInt(time.Now().Unix(), 10)
	nonce := "bash_openssl_interop_987654321"
	script := fmt.Sprintf(`
set -e
TOKEN=%q
SECRET=%q
TS=%q
NONCE=%q
BODY='{"days":30}'
BODY_SHA=$(printf '%%s' "$BODY" | openssl dgst -sha256 | awk '{print $NF}')
TOK_SHA=$(printf '%%s' "$TOKEN" | openssl dgst -sha256 | awk '{print $NF}')
CANON=$(printf 'POST\n/api/accounts/vless/alice/renew\n\n%%s\n%%s\n%%s\n%%s' "$TS" "$NONCE" "$BODY_SHA" "$TOK_SHA")
CANON_SHA=$(printf '%%s' "$CANON" | openssl dgst -sha256 | awk '{print $NF}')
SIGN_STR="ASv5.5:${TS}:${CANON_SHA}"
SIG=$(printf '%%s' "$SIGN_STR" | openssl dgst -sha256 -hmac "$SECRET" | awk '{print $NF}')
printf '%%s|%%s' "$BODY_SHA" "$SIG"
`, token, secret, ts, nonce)

	out, err := exec.Command("bash", "-c", script).CombinedOutput()
	if err != nil {
		t.Fatalf("bash openssl script failed: %s: %v", string(out), err)
	}
	parts := strings.Split(strings.TrimSpace(string(out)), "|")
	if len(parts) != 2 {
		t.Fatalf("unexpected script output: %s", string(out))
	}

	_, authErr := v.VerifyRequest(
		"127.0.0.1",
		"POST",
		"/api/accounts/vless/alice/renew",
		"",
		"Bearer "+token,
		parts[0],
		ts,
		nonce,
		parts[1],
		[]byte(`{"days":30}`),
	)
	if authErr != nil {
		t.Fatalf("Bash/OpenSSL generated signature failed Go verifier: %+v", authErr)
	}
}

func BenchmarkVerifierParallel(b *testing.B) {
	v, token, secret := setupTestVerifier(b, nil)
	body := []byte(`{"count":100,"prefix":"flash_","days":30}`)
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	var seq atomic.Uint64

	b.ResetTimer()
	b.RunParallel(func(pb *testing.PB) {
		for pb.Next() {
			id := seq.Add(1)
			nonce := fmt.Sprintf("bench_nonce_%016x", id)
			bodySHA, sig := SignRequest("POST", "/api/accounts/vless", "", token, secret, ts, nonce, body)
			_, err := v.VerifyRequest("127.0.0.1", "POST", "/api/accounts/vless", "", "Bearer "+token, bodySHA, ts, nonce, sig, body)
			if err != nil {
				b.Fatalf("verify failed: %+v", err)
			}
		}
	})
}
