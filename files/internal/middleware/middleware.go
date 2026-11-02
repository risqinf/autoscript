package middleware

import (
	"context"
	"encoding/json"
	"hash/fnv"
	"strconv"
	"sync"
	"time"

	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/risqinf/autoscript-api/internal/security"
	"github.com/rs/zerolog"
	"github.com/valyala/fasthttp"
)

// AuthMiddleware enforces multi-layered SHA-256 verification and mutual server response signing.
type AuthMiddleware struct {
	verifier *security.Verifier
	logger   *zerolog.Logger
}

// NewAuthMiddleware creates a new AuthMiddleware backed by a SHA-256 Verifier.
func NewAuthMiddleware(repo repository.APIRepository, logger *zerolog.Logger) *AuthMiddleware {
	cfg, _ := config.Load()
	return NewAuthMiddlewareWithVerifier(security.NewVerifier(repo, cfg), logger)
}

// NewAuthMiddlewareWithVerifier creates a new AuthMiddleware using an explicit Verifier.
func NewAuthMiddlewareWithVerifier(verifier *security.Verifier, logger *zerolog.Logger) *AuthMiddleware {
	return &AuthMiddleware{
		verifier: verifier,
		logger:   logger,
	}
}

// Verifier returns the underlying SHA-256 Verifier.
func (m *AuthMiddleware) Verifier() *security.Verifier {
	return m.verifier
}

// SignAndHardenResponse applies security headers and mutual SHA-256 response signatures to any response.
func (m *AuthMiddleware) SignAndHardenResponse(ctx *fasthttp.RequestCtx) {
	ctx.Response.Header.Set("X-Content-Type-Options", "nosniff")
	ctx.Response.Header.Set("X-Frame-Options", "DENY")
	ctx.Response.Header.Set("Cache-Control", "no-store")
	ctx.Response.Header.Set("Referrer-Policy", "no-referrer")

	if m.verifier == nil {
		return
	}

	reqID, _ := ctx.UserValue("request_id").(string)
	if reqID == "" {
		reqID = m.verifier.NextRequestID()
		ctx.SetUserValue("request_id", reqID)
	}

	respTS := strconv.FormatInt(time.Now().Unix(), 10)
	respSHA, srvSig := m.verifier.SignResponse(reqID, respTS, ctx.Response.Body())

	ctx.Response.Header.Set("X-Request-ID", reqID)
	ctx.Response.Header.Set("X-Response-Timestamp", respTS)
	ctx.Response.Header.Set("X-Response-SHA256", respSHA)
	ctx.Response.Header.Set("X-Server-Signature", srvSig)
}

// SignResponseMiddleware guarantees every HTTP response (including recovered panics) carries mutual SHA-256 signatures.
func (m *AuthMiddleware) SignResponseMiddleware(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		if m.verifier != nil && ctx.UserValue("request_id") == nil {
			ctx.SetUserValue("request_id", m.verifier.NextRequestID())
		}
		defer m.SignAndHardenResponse(ctx)
		next(ctx)
	}
}

// Handle validates all 5 cryptographic SHA-256 layers on protected routes.
func (m *AuthMiddleware) Handle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		reqID, _ := ctx.UserValue("request_id").(string)
		if reqID == "" && m.verifier != nil {
			reqID = m.verifier.NextRequestID()
			ctx.SetUserValue("request_id", reqID)
		}

		clientIP := security.ExtractClientIP(
			ctx.RemoteIP(),
			string(ctx.Request.Header.Peek("X-Real-IP")),
			string(ctx.Request.Header.Peek("X-Forwarded-For")),
		)
		ctx.SetUserValue("client_ip", clientIP)

		res, authErr := m.verifier.VerifyRequest(
			clientIP,
			string(ctx.Method()),
			string(ctx.Path()),
			string(ctx.URI().QueryString()),
			string(ctx.Request.Header.Peek("Authorization")),
			string(ctx.Request.Header.Peek("X-Content-SHA256")),
			string(ctx.Request.Header.Peek("X-Timestamp")),
			string(ctx.Request.Header.Peek("X-Nonce")),
			string(ctx.Request.Header.Peek("X-Signature")),
			ctx.PostBody(),
		)
		if authErr != nil {
			writeError(ctx, authErr.HTTPCode, authErr.ErrType, authErr.Message)
			return
		}

		ctx.SetUserValue("auth_result", res)
		next(ctx)
	}
}

// PublicHandle attaches request IDs, security headers, and mutual server response signing on public routes.
func (m *AuthMiddleware) PublicHandle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return m.SignResponseMiddleware(next)
}

// LoggerMiddleware provides panic recovery, structured request logging, and non-blocking batched SQLite audit logging.
type LoggerMiddleware struct {
	repo    repository.APIRepository
	logger  *zerolog.Logger
	logCh   chan repository.APILogEntry
	stopCh  chan struct{}
	stopOne sync.Once
}

// NewLoggerMiddleware creates a new LoggerMiddleware.
func NewLoggerMiddleware(logger *zerolog.Logger) *LoggerMiddleware {
	return NewLoggerMiddlewareWithRepo(nil, logger)
}

// NewLoggerMiddlewareWithRepo creates a new LoggerMiddleware with async batched SQLite persistence.
func NewLoggerMiddlewareWithRepo(repo repository.APIRepository, logger *zerolog.Logger) *LoggerMiddleware {
	m := &LoggerMiddleware{
		repo:   repo,
		logger: logger,
		logCh:  make(chan repository.APILogEntry, 8192),
		stopCh: make(chan struct{}),
	}
	if repo != nil {
		go m.flushWorker()
	}
	return m
}

// Close flushes remaining logs and stops the background worker.
func (m *LoggerMiddleware) Close() {
	m.stopOne.Do(func() {
		close(m.stopCh)
	})
}

func (m *LoggerMiddleware) flushWorker() {
	ticker := time.NewTicker(2 * time.Second)
	pruneTicker := time.NewTicker(5 * time.Minute)
	defer ticker.Stop()
	defer pruneTicker.Stop()

	batch := make([]repository.APILogEntry, 0, 256)
	flush := func() {
		if len(batch) == 0 || m.repo == nil {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_ = m.repo.LogRequestBatch(ctx, batch)
		cancel()
		batch = batch[:0]
	}

	for {
		select {
		case <-m.stopCh:
			for {
				select {
				case item := <-m.logCh:
					batch = append(batch, item)
					if len(batch) >= 500 {
						flush()
					}
				default:
					flush()
					return
				}
			}
		case item := <-m.logCh:
			batch = append(batch, item)
			if len(batch) >= 256 {
				flush()
			}
		case <-ticker.C:
			flush()
		case <-pruneTicker.C:
			if m.repo != nil {
				ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
				_ = m.repo.PruneLogs(ctx, 10000)
				cancel()
			}
		}
	}
}

// Handle wraps requests with panic recovery and non-blocking telemetry logging.
func (m *LoggerMiddleware) Handle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		start := time.Now()

		defer func() {
			if rec := recover(); rec != nil {
				if m.logger != nil {
					m.logger.Error().Interface("panic", rec).Str("path", string(ctx.Path())).Msg("recovered panic in HTTP handler")
				}
				writeError(ctx, fasthttp.StatusInternalServerError, model.ErrInternal, "Internal server error")
			}

			elapsed := time.Since(start)
			clientIP, _ := ctx.UserValue("client_ip").(string)
			if clientIP == "" {
				clientIP = security.ExtractClientIP(
					ctx.RemoteIP(),
					string(ctx.Request.Header.Peek("X-Real-IP")),
					string(ctx.Request.Header.Peek("X-Forwarded-For")),
				)
			}

			status := ctx.Response.StatusCode()
			if m.repo != nil {
				select {
				case m.logCh <- repository.APILogEntry{
					Timestamp: start.Unix(),
					Method:    string(ctx.Method()),
					Path:      string(ctx.Path()),
					IP:        clientIP,
					Status:    status,
					LatencyMs: float64(elapsed.Microseconds()) / 1000.0,
				}:
				default:
					// Ring buffer full under extreme million-RPS burst: drop audit log entry instead of blocking worker
				}
			}

			if m.logger != nil && status >= 400 {
				m.logger.Warn().
					Str("method", string(ctx.Method())).
					Str("path", string(ctx.Path())).
					Int("status", status).
					Dur("latency", elapsed).
					Str("ip", clientIP).
					Msg("request completed with error status")
			}
		}()

		next(ctx)
	}
}

const rlShards = 256

type ipWindowCounter struct {
	count   int
	resetAt int64
}

type rlShard struct {
	mu      sync.Mutex
	buckets map[string]*ipWindowCounter
}

// RateLimiter implements a 256-shard high-throughput in-memory rate limiter capable of millions of checks/sec.
type RateLimiter struct {
	shards    [rlShards]rlShard
	limit     int
	authLimit int
	windowSec int64
	logger    *zerolog.Logger
	stopCh    chan struct{}
	stopOne   sync.Once
}

// NewRateLimiter creates a 256-shard in-memory RateLimiter (keeps signature compatible while eliminating SQLite bottlenecks).
func NewRateLimiter(_ repository.APIRepository, limit, window int, logger *zerolog.Logger) *RateLimiter {
	return NewHighThroughputRateLimiter(limit, limit*20, window, logger)
}

// NewHighThroughputRateLimiter creates a 256-shard RateLimiter with distinct unauthenticated and authenticated burst ceilings.
func NewHighThroughputRateLimiter(limit, authBurstLimit, window int, logger *zerolog.Logger) *RateLimiter {
	if limit <= 0 {
		limit = 5000
	}
	if authBurstLimit < limit {
		authBurstLimit = limit * 20
	}
	if window <= 0 {
		window = 60
	}

	rl := &RateLimiter{
		limit:     limit,
		authLimit: authBurstLimit,
		windowSec: int64(window),
		logger:    logger,
		stopCh:    make(chan struct{}),
	}
	for i := range rl.shards {
		rl.shards[i].buckets = make(map[string]*ipWindowCounter, 32)
	}
	go rl.cleanupLoop()
	return rl
}

// Close stops background rate limiter cleanup.
func (m *RateLimiter) Close() {
	m.stopOne.Do(func() {
		close(m.stopCh)
	})
}

func (m *RateLimiter) shardFor(ip string) *rlShard {
	h := fnv.New32a()
	_, _ = h.Write([]byte(ip))
	return &m.shards[h.Sum32()&(rlShards-1)]
}

func (m *RateLimiter) cleanupLoop() {
	ticker := time.NewTicker(60 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-m.stopCh:
			return
		case <-ticker.C:
			now := time.Now().Unix()
			for i := range m.shards {
				sh := &m.shards[i]
				sh.mu.Lock()
				for k, v := range sh.buckets {
					if now >= v.resetAt {
						delete(sh.buckets, k)
					}
				}
				sh.mu.Unlock()
			}
		}
	}
}

// Allow checks and increments the counter for ip, returning (allowed, remaining, resetUnix, ceiling).
func (m *RateLimiter) Allow(ip string, authenticated bool) (bool, int, int64, int) {
	ceiling := m.limit
	key := ip
	if authenticated {
		ceiling = m.authLimit
		key = "auth:" + ip
	}

	now := time.Now().Unix()
	sh := m.shardFor(key)

	sh.mu.Lock()
	b, ok := sh.buckets[key]
	if !ok || now >= b.resetAt {
		if len(sh.buckets) >= 16384 {
			for k, v := range sh.buckets {
				if now >= v.resetAt {
					delete(sh.buckets, k)
				}
			}
		}
		b = &ipWindowCounter{
			count:   1,
			resetAt: now + m.windowSec,
		}
		sh.buckets[key] = b
		rem := ceiling - 1
		resetAt := b.resetAt
		sh.mu.Unlock()
		return true, rem, resetAt, ceiling
	}

	if b.count >= ceiling {
		resetAt := b.resetAt
		sh.mu.Unlock()
		return false, 0, resetAt, ceiling
	}

	b.count++
	rem := ceiling - b.count
	resetAt := b.resetAt
	sh.mu.Unlock()
	return true, rem, resetAt, ceiling
}

// Handle enforces sharded in-memory rate limits and emits standard X-RateLimit-* headers.
func (m *RateLimiter) Handle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		clientIP, _ := ctx.UserValue("client_ip").(string)
		if clientIP == "" {
			clientIP = security.ExtractClientIP(
				ctx.RemoteIP(),
				string(ctx.Request.Header.Peek("X-Real-IP")),
				string(ctx.Request.Header.Peek("X-Forwarded-For")),
			)
		}

		isAuth := ctx.UserValue("auth_result") != nil
		allowed, remaining, resetAt, ceiling := m.Allow(clientIP, isAuth)

		ctx.Response.Header.Set("X-RateLimit-Limit", strconv.Itoa(ceiling))
		ctx.Response.Header.Set("X-RateLimit-Remaining", strconv.Itoa(remaining))
		ctx.Response.Header.Set("X-RateLimit-Reset", strconv.FormatInt(resetAt, 10))

		if !allowed {
			writeError(ctx, fasthttp.StatusTooManyRequests, model.ErrRateLimited, "Rate limit exceeded; retry after reset window")
			return
		}

		next(ctx)
	}
}

func writeError(ctx *fasthttp.RequestCtx, code int, errType, message string) {
	ctx.SetStatusCode(code)
	ctx.SetContentType("application/json")
	resp := model.NewErrorResponse(code, errType, message, nil)
	data, _ := json.Marshal(resp)
	ctx.SetBody(data)
}
