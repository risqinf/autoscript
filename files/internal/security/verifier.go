package security

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"net"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
)

const (
	nonceShardCount      = 256
	maxNoncesPerShard    = 65536
	EmptyBodySHA256Hex   = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
	SignatureVersionTag  = "ASv5.5"
	ResponseSignatureTag = "ASv5.5-RESP"
)

type cachedToken struct {
	Name      string
	RawToken  string
	Digest    [32]byte
	DigestHex string
}

type nonceShard struct {
	mu    sync.Mutex
	items map[[32]byte]int64 // sha256(nonce) -> expiryUnix
}

// VerificationResult contains metadata about a cryptographically verified request.
type VerificationResult struct {
	TokenName       string   `json:"token_name"`
	ClientIP        string   `json:"client_ip"`
	SecurityMode    string   `json:"security_mode"`
	VerifiedLayers  []string `json:"verified_layers"`
	BodySHA256      string   `json:"body_sha256"`
	TokenSHA256     string   `json:"token_sha256"`
	CanonicalSHA256 string   `json:"canonical_sha256,omitempty"`
	Timestamp       int64    `json:"timestamp,omitempty"`
	Nonce           string   `json:"nonce,omitempty"`
}

// AuthError represents a structured authentication/verification rejection.
type AuthError struct {
	HTTPCode int
	ErrType  string
	Message  string
}

func (e *AuthError) Error() string {
	return e.Message
}

// Verifier enforces Multi-Layered SHA-256 request verification and mutual server response signing.
type Verifier struct {
	repo       repository.APIRepository
	cfg        *config.Config
	tokensPtr  atomic.Pointer[[]cachedToken]
	secretPtr  atomic.Pointer[string]
	allowedNet []*net.IPNet
	allowedIP  []net.IP
	shards     [nonceShardCount]nonceShard

	touchedMu sync.Mutex
	touched   map[string]int64

	reqSeq  atomic.Uint64
	bootPfx string
	stopCh  chan struct{}
	stopOne sync.Once
}

// NewVerifier creates and initializes a multi-layered SHA-256 Verifier.
func NewVerifier(repo repository.APIRepository, cfg *config.Config) *Verifier {
	var bootBytes [4]byte
	_, _ = rand.Read(bootBytes[:])

	v := &Verifier{
		repo:    repo,
		cfg:     cfg,
		touched: make(map[string]int64, 16),
		bootPfx: hex.EncodeToString(bootBytes[:]),
		stopCh:  make(chan struct{}),
	}

	sec := cfg.APISecret
	v.secretPtr.Store(&sec)

	empty := make([]cachedToken, 0)
	v.tokensPtr.Store(&empty)

	for i := range v.shards {
		v.shards[i].items = make(map[[32]byte]int64, 64)
	}

	v.parseAllowedIPs(cfg.AllowedIPs)
	_ = v.RefreshTokens(context.Background())

	go v.backgroundMaintenance()
	return v
}

// Close stops background maintenance goroutines cleanly.
func (v *Verifier) Close() {
	v.stopOne.Do(func() {
		close(v.stopCh)
	})
}

func (v *Verifier) parseAllowedIPs(entries []string) {
	for _, raw := range entries {
		raw = strings.TrimSpace(raw)
		if raw == "" {
			continue
		}
		if strings.Contains(raw, "/") {
			if _, ipnet, err := net.ParseCIDR(raw); err == nil {
				v.allowedNet = append(v.allowedNet, ipnet)
			}
		} else if ip := net.ParseIP(raw); ip != nil {
			v.allowedIP = append(v.allowedIP, ip)
		}
	}
}

// RefreshTokens reloads active Bearer tokens from SQLite + /etc/api/key and updates the secret key atomically.
func (v *Verifier) RefreshTokens(ctx context.Context) error {
	if v.cfg != nil {
		if latestSec := v.cfg.ReloadSecret(); latestSec != "" {
			v.secretPtr.Store(&latestSec)
		}
		if v.repo != nil && v.cfg.APIKeyFile != "" {
			_, _ = v.repo.SyncKeyFile(ctx, v.cfg.APIKeyFile)
		}
	}

	if v.repo == nil {
		return nil
	}

	list, err := v.repo.ListTokens(ctx)
	if err != nil {
		return err
	}

	cached := make([]cachedToken, 0, len(list))
	for _, t := range list {
		tok := strings.TrimSpace(t.Token)
		if tok == "" {
			continue
		}
		sum := sha256.Sum256([]byte(tok))
		cached = append(cached, cachedToken{
			Name:      t.Name,
			RawToken:  tok,
			Digest:    sum,
			DigestHex: hex.EncodeToString(sum[:]),
		})
	}
	v.tokensPtr.Store(&cached)
	return nil
}

// ActiveSecret returns the current HMAC secret string atomically.
func (v *Verifier) ActiveSecret() string {
	if p := v.secretPtr.Load(); p != nil {
		return *p
	}
	if v.cfg != nil {
		return v.cfg.APISecret
	}
	return ""
}

// NextRequestID returns an ultra-fast collision-free hex request identifier (zero syscalls on hot path).
func (v *Verifier) NextRequestID() string {
	seq := v.reqSeq.Add(1)
	var b [8]byte
	binary.BigEndian.PutUint64(b[:], seq)
	return v.bootPfx + hex.EncodeToString(b[:])
}

// ExtractClientIP extracts the true client IP safely, trusting X-Real-IP / X-Forwarded-For ONLY from loopback proxies.
func ExtractClientIP(remoteIP net.IP, xRealIP, xForwardedFor string) string {
	if remoteIP != nil && remoteIP.IsLoopback() {
		if xrip := strings.TrimSpace(xRealIP); xrip != "" {
			if parsed := net.ParseIP(xrip); parsed != nil {
				return parsed.String()
			}
		}
		if xff := strings.TrimSpace(xForwardedFor); xff != "" {
			first := strings.TrimSpace(strings.SplitN(xff, ",", 2)[0])
			if parsed := net.ParseIP(first); parsed != nil {
				return parsed.String()
			}
		}
	}
	if remoteIP != nil {
		return remoteIP.String()
	}
	return "0.0.0.0"
}

// IsIPAllowed checks Layer 0 IP/CIDR allowlist.
func (v *Verifier) IsIPAllowed(ipStr string) bool {
	if len(v.allowedIP) == 0 && len(v.allowedNet) == 0 {
		return true
	}
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return false
	}
	if ip.IsLoopback() {
		return true
	}
	for _, allowed := range v.allowedIP {
		if allowed.Equal(ip) {
			return true
		}
	}
	for _, cidr := range v.allowedNet {
		if cidr.Contains(ip) {
			return true
		}
	}
	return false
}

// VerifyRequest executes the strict 5-layer SHA-256 verification pipeline.
func (v *Verifier) VerifyRequest(
	clientIP string,
	method string,
	path string,
	rawQuery string,
	authHeader string,
	contentSHAHeader string,
	timestampHeader string,
	nonceHeader string,
	signatureHeader string,
	rawBody []byte,
) (*VerificationResult, *AuthError) {
	// Layer 0: Optional IP/CIDR Allowlist
	if !v.IsIPAllowed(clientIP) {
		return nil, &AuthError{
			HTTPCode: 403,
			ErrType:  model.ErrForbiddenIP,
			Message:  "Client IP is not permitted by API allowlist",
		}
	}

	// Layer 1: Constant-Time SHA-256 Bearer Token Verification
	if len(authHeader) <= 7 || !strings.EqualFold(authHeader[:7], "Bearer ") {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrUnauthorized,
			Message:  "Missing or invalid Authorization Bearer header",
		}
	}
	rawToken := strings.TrimSpace(authHeader[7:])
	if rawToken == "" {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrUnauthorized,
			Message:  "Empty Bearer token",
		}
	}

	matchedToken, ok := v.matchTokenConstantTime(rawToken)
	if !ok {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrUnauthorized,
			Message:  "Invalid API Bearer token",
		}
	}

	v.markTokenUsed(matchedToken.RawToken)

	// Compute actual SHA-256 of raw request body
	var actualBodyHex string
	if len(rawBody) == 0 {
		actualBodyHex = EmptyBodySHA256Hex
	} else {
		bodySum := sha256.Sum256(rawBody)
		actualBodyHex = hex.EncodeToString(bodySum[:])
	}

	mode := "strict"
	if v.cfg != nil && v.cfg.SecurityMode == "compat" {
		mode = "compat"
	}

	// In compat mode, if caller omits X-Signature, allow Layer 1 + optional Layer 2 if provided.
	if mode == "compat" && signatureHeader == "" && contentSHAHeader == "" && timestampHeader == "" && nonceHeader == "" {
		return &VerificationResult{
			TokenName:      matchedToken.Name,
			ClientIP:       clientIP,
			SecurityMode:   "compat",
			VerifiedLayers: []string{"layer1_bearer_sha256"},
			BodySHA256:     actualBodyHex,
			TokenSHA256:    matchedToken.DigestHex,
		}, nil
	}

	// Layer 2: Strict Raw Payload SHA-256 Integrity (X-Content-SHA256)
	claimedBodyHex := strings.ToLower(strings.TrimSpace(contentSHAHeader))
	if len(claimedBodyHex) != 64 || !isHexString(claimedBodyHex) {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrInvalidContentHash,
			Message:  "Missing or malformed X-Content-SHA256 header (64-char hex SHA-256 required)",
		}
	}
	if subtle.ConstantTimeCompare([]byte(claimedBodyHex), []byte(actualBodyHex)) != 1 {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrInvalidContentHash,
			Message:  "X-Content-SHA256 mismatch: request body integrity check failed",
		}
	}

	// Layer 3: Strict Timestamp Anti-Drift Window (X-Timestamp)
	tsStr := strings.TrimSpace(timestampHeader)
	reqTS, err := strconv.ParseInt(tsStr, 10, 64)
	if err != nil || reqTS <= 0 {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrTimestampExpired,
			Message:  "Missing or invalid X-Timestamp header (Unix epoch seconds required)",
		}
	}
	nowTS := time.Now().Unix()
	maxSkew := int64(300)
	if v.cfg != nil && v.cfg.MaxSkewSec > 0 {
		maxSkew = v.cfg.MaxSkewSec
	}
	drift := nowTS - reqTS
	if drift < 0 {
		drift = -drift
	}
	if drift > maxSkew {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrTimestampExpired,
			Message:  fmt.Sprintf("X-Timestamp outside allowed ±%ds clock skew window", maxSkew),
		}
	}

	// Pre-validate Layer 4 Nonce format before Layer 5 HMAC calculation
	nonce := strings.TrimSpace(nonceHeader)
	if !isValidNonce(nonce) {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrReplayDetected,
			Message:  "Missing or invalid X-Nonce header (16-128 alphanumeric/hex/dash chars required)",
		}
	}

	// Layer 5: Multi-Layer Canonical HMAC-SHA256 Signature (X-Signature)
	claimedSigHex := strings.ToLower(strings.TrimSpace(signatureHeader))
	if len(claimedSigHex) != 64 || !isHexString(claimedSigHex) {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrInvalidSignature,
			Message:  "Missing or malformed X-Signature header (64-char hex HMAC-SHA256 required)",
		}
	}

	canonicalHashHex, expectedSigHex := ComputeCanonicalSignature(
		strings.ToUpper(method),
		path,
		rawQuery,
		tsStr,
		nonce,
		actualBodyHex,
		matchedToken.DigestHex,
		v.ActiveSecret(),
	)

	if subtle.ConstantTimeCompare([]byte(claimedSigHex), []byte(expectedSigHex)) != 1 {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrInvalidSignature,
			Message:  "X-Signature cryptographic verification failed",
		}
	}

	// Layer 4 Commit: Atomically claim X-Nonce in sharded anti-replay store AFTER signature succeeds
	if !v.claimNonce(nonce, nowTS, maxSkew*2+15) {
		return nil, &AuthError{
			HTTPCode: 401,
			ErrType:  model.ErrReplayDetected,
			Message:  "Replay attack detected: X-Nonce has already been used",
		}
	}

	return &VerificationResult{
		TokenName:       matchedToken.Name,
		ClientIP:        clientIP,
		SecurityMode:    "strict",
		VerifiedLayers:  []string{"layer0_ip_policy", "layer1_bearer_sha256", "layer2_content_sha256", "layer3_timestamp_window", "layer4_nonce_antireplay", "layer5_canonical_hmac_sha256"},
		BodySHA256:      actualBodyHex,
		TokenSHA256:     matchedToken.DigestHex,
		CanonicalSHA256: canonicalHashHex,
		Timestamp:       reqTS,
		Nonce:           nonce,
	}, nil
}

// ComputeCanonicalSignature implements the deterministic multi-layer SHA-256 + HMAC-SHA256 envelope:
//  1. canonical = METHOD + "\n" + PATH + "\n" + CANONICAL_QUERY + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + BODY_SHA256 + "\n" + TOKEN_SHA256
//  2. canonicalHash = hex(sha256(canonical))
//  3. signingString = "ASv5.5:" + TIMESTAMP + ":" + canonicalHash
//  4. signature = hex(hmac_sha256(secret, signingString))
func ComputeCanonicalSignature(
	method, path, rawQuery, timestamp, nonce, bodySHA256Hex, tokenSHA256Hex, secret string,
) (canonicalHashHex string, signatureHex string) {
	canonQuery := CanonicalizeQuery(rawQuery)
	if path == "" {
		path = "/"
	}

	var sb strings.Builder
	sb.Grow(len(method) + len(path) + len(canonQuery) + len(timestamp) + len(nonce) + 140)
	sb.WriteString(strings.ToUpper(method))
	sb.WriteByte('\n')
	sb.WriteString(path)
	sb.WriteByte('\n')
	sb.WriteString(canonQuery)
	sb.WriteByte('\n')
	sb.WriteString(timestamp)
	sb.WriteByte('\n')
	sb.WriteString(nonce)
	sb.WriteByte('\n')
	sb.WriteString(strings.ToLower(bodySHA256Hex))
	sb.WriteByte('\n')
	sb.WriteString(strings.ToLower(tokenSHA256Hex))

	canonSum := sha256.Sum256([]byte(sb.String()))
	canonicalHashHex = hex.EncodeToString(canonSum[:])

	signingString := SignatureVersionTag + ":" + timestamp + ":" + canonicalHashHex
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signingString))
	signatureHex = hex.EncodeToString(mac.Sum(nil))

	return canonicalHashHex, signatureHex
}

// SignRequest computes all required client security headers for any HTTP request.
func SignRequest(method, path, rawQuery, token, secret, timestamp, nonce string, body []byte) (bodySHA256, signature string) {
	if len(body) == 0 {
		bodySHA256 = EmptyBodySHA256Hex
	} else {
		bSum := sha256.Sum256(body)
		bodySHA256 = hex.EncodeToString(bSum[:])
	}
	tSum := sha256.Sum256([]byte(token))
	tokenSHA256 := hex.EncodeToString(tSum[:])

	_, signature = ComputeCanonicalSignature(method, path, rawQuery, timestamp, nonce, bodySHA256, tokenSHA256, secret)
	return bodySHA256, signature
}

// SignResponse computes mutual server response authentication headers (`X-Response-SHA256` & `X-Server-Signature`).
func (v *Verifier) SignResponse(requestID, respTimestamp string, respBody []byte) (respSHA256, serverSig string) {
	if len(respBody) == 0 {
		respSHA256 = EmptyBodySHA256Hex
	} else {
		sum := sha256.Sum256(respBody)
		respSHA256 = hex.EncodeToString(sum[:])
	}

	signingStr := ResponseSignatureTag + ":" + respTimestamp + ":" + requestID + ":" + respSHA256
	mac := hmac.New(sha256.New, []byte(v.ActiveSecret()))
	_, _ = mac.Write([]byte(signingStr))
	serverSig = hex.EncodeToString(mac.Sum(nil))
	return respSHA256, serverSig
}

// VerifyServerResponse verifies mutual server response signature headers on the client side.
func VerifyServerResponse(secret, requestID, respTimestamp, claimedRespSHA256, claimedServerSig string, respBody []byte) bool {
	var actualSHA string
	if len(respBody) == 0 {
		actualSHA = EmptyBodySHA256Hex
	} else {
		sum := sha256.Sum256(respBody)
		actualSHA = hex.EncodeToString(sum[:])
	}
	if subtle.ConstantTimeCompare([]byte(strings.ToLower(claimedRespSHA256)), []byte(actualSHA)) != 1 {
		return false
	}
	signingStr := ResponseSignatureTag + ":" + respTimestamp + ":" + requestID + ":" + actualSHA
	mac := hmac.New(sha256.New, []byte(secret))
	_, _ = mac.Write([]byte(signingStr))
	expected := hex.EncodeToString(mac.Sum(nil))
	return subtle.ConstantTimeCompare([]byte(strings.ToLower(claimedServerSig)), []byte(expected)) == 1
}

// CanonicalizeQuery sorts query parameters lexicographically and encodes them per RFC 3986.
func CanonicalizeQuery(rawQuery string) string {
	rawQuery = strings.TrimPrefix(rawQuery, "?")
	if rawQuery == "" {
		return ""
	}
	vals, err := url.ParseQuery(rawQuery)
	if err != nil || len(vals) == 0 {
		return ""
	}

	keys := make([]string, 0, len(vals))
	for k := range vals {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var parts []string
	for _, k := range keys {
		vs := vals[k]
		sortedVals := make([]string, len(vs))
		copy(sortedVals, vs)
		sort.Strings(sortedVals)
		encKey := rfc3986Escape(k)
		for _, val := range sortedVals {
			parts = append(parts, encKey+"="+rfc3986Escape(val))
		}
	}
	return strings.Join(parts, "&")
}

func rfc3986Escape(s string) string {
	return strings.ReplaceAll(url.QueryEscape(s), "+", "%20")
}

func (v *Verifier) matchTokenConstantTime(incoming string) (cachedToken, bool) {
	incomingDigest := sha256.Sum256([]byte(incoming))
	tokens := v.tokensPtr.Load()

	var matched cachedToken
	found := 0
	if tokens != nil {
		for _, entry := range *tokens {
			if subtle.ConstantTimeCompare(entry.Digest[:], incomingDigest[:]) == 1 {
				matched = entry
				found = 1
			}
		}
	}
	if found == 1 {
		return matched, true
	}

	// Fallback single refresh in case token was just inserted via CLI seconds ago
	if v.repo != nil {
		_ = v.RefreshTokens(context.Background())
		tokens = v.tokensPtr.Load()
		if tokens != nil {
			for _, entry := range *tokens {
				if subtle.ConstantTimeCompare(entry.Digest[:], incomingDigest[:]) == 1 {
					matched = entry
					found = 1
				}
			}
		}
	}
	return matched, found == 1
}

func (v *Verifier) claimNonce(nonce string, nowTS, ttlSec int64) bool {
	digest := sha256.Sum256([]byte(nonce))
	shard := &v.shards[digest[0]] // 0..255 uniform distribution via SHA-256 first byte

	shard.mu.Lock()
	defer shard.mu.Unlock()

	if exp, exists := shard.items[digest]; exists && nowTS < exp {
		return false
	}

	if len(shard.items) >= maxNoncesPerShard {
		for k, exp := range shard.items {
			if nowTS >= exp {
				delete(shard.items, k)
			}
		}
		if len(shard.items) >= maxNoncesPerShard {
			// Evict one arbitrary oldest/random entry to guarantee bounded memory on 1GB VPS
			for k := range shard.items {
				delete(shard.items, k)
				break
			}
		}
	}

	shard.items[digest] = nowTS + ttlSec
	return true
}

func (v *Verifier) markTokenUsed(rawToken string) {
	v.touchedMu.Lock()
	v.touched[rawToken] = time.Now().Unix()
	v.touchedMu.Unlock()
}

func (v *Verifier) backgroundMaintenance() {
	refreshTicker := time.NewTicker(5 * time.Second)
	sweepTicker := time.NewTicker(30 * time.Second)
	defer refreshTicker.Stop()
	defer sweepTicker.Stop()

	for {
		select {
		case <-v.stopCh:
			return
		case <-refreshTicker.C:
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			_ = v.RefreshTokens(ctx)
			cancel()
		case <-sweepTicker.C:
			now := time.Now().Unix()
			for i := range v.shards {
				sh := &v.shards[i]
				sh.mu.Lock()
				for k, exp := range sh.items {
					if now >= exp {
						delete(sh.items, k)
					}
				}
				sh.mu.Unlock()
			}
			v.flushTouchedTokens()
		}
	}
}

func (v *Verifier) flushTouchedTokens() {
	if v.repo == nil {
		return
	}
	v.touchedMu.Lock()
	if len(v.touched) == 0 {
		v.touchedMu.Unlock()
		return
	}
	snapshot := v.touched
	v.touched = make(map[string]int64, len(snapshot))
	v.touchedMu.Unlock()

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for tok, ts := range snapshot {
		_ = v.repo.TouchTokenLastUsed(ctx, tok, ts)
	}
}

func isHexString(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func isValidNonce(s string) bool {
	if len(s) < 16 || len(s) > 128 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '-' || c == '_') {
			return false
		}
	}
	return true
}
