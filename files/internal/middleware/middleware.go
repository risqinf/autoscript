package middleware

import (
	"encoding/json"
	"strings"
	"time"

	"github.com/valyala/fasthttp"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/repository"
	"github.com/rs/zerolog"
)

// AuthMiddleware validates Bearer tokens.
type AuthMiddleware struct {
	repo   repository.APIRepository
	logger *zerolog.Logger
}

// NewAuthMiddleware creates a new AuthMiddleware.
func NewAuthMiddleware(repo repository.APIRepository, logger *zerolog.Logger) *AuthMiddleware {
	return &AuthMiddleware{repo: repo, logger: logger}
}

// Handle validates the Authorization header.
func (m *AuthMiddleware) Handle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		// Extract token
		authHeader := string(ctx.Request.Header.Peek("Authorization"))
		if !strings.HasPrefix(authHeader, "Bearer ") {
			writeError(ctx, fasthttp.StatusUnauthorized, model.ErrUnauthorized, "Missing or invalid Authorization header")
			return
		}
		token := strings.TrimPrefix(authHeader, "Bearer ")

		// Validate token
		valid, err := m.repo.ValidateToken(ctx, token)
		if err != nil {
			m.logger.Error().Err(err).Msg("token validation error")
			writeError(ctx, fasthttp.StatusInternalServerError, model.ErrInternal, "Internal server error")
			return
		}
		if !valid {
			writeError(ctx, fasthttp.StatusUnauthorized, model.ErrUnauthorized, "Invalid token")
			return
		}

		// Token valid, continue
		next(ctx)
	}
}

// LoggerMiddleware logs HTTP requests.
type LoggerMiddleware struct {
	logger *zerolog.Logger
}

// NewLoggerMiddleware creates a new LoggerMiddleware.
func NewLoggerMiddleware(logger *zerolog.Logger) *LoggerMiddleware {
	return &LoggerMiddleware{logger: logger}
}

// Handle logs the request.
func (m *LoggerMiddleware) Handle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		start := time.Now()

		// Process request
		next(ctx)

		// Log request
		m.logger.Info().
			Str("method", string(ctx.Method())).
			Str("path", string(ctx.Path())).
			Int("status", ctx.Response.StatusCode()).
			Dur("latency", time.Since(start)).
			Str("ip", ctx.RemoteIP().String()).
			Msg("request processed")
	}
}

// RateLimiter limits requests per IP.
type RateLimiter struct {
	repo       repository.APIRepository
	limit      int
	window     int
	logger     *zerolog.Logger
}

// NewRateLimiter creates a new RateLimiter.
func NewRateLimiter(repo repository.APIRepository, limit, window int, logger *zerolog.Logger) *RateLimiter {
	return &RateLimiter{
		repo:   repo,
		limit:  limit,
		window: window,
		logger: logger,
	}
}

// Handle checks rate limit.
func (m *RateLimiter) Handle(next fasthttp.RequestHandler) fasthttp.RequestHandler {
	return func(ctx *fasthttp.RequestCtx) {
		ip := ctx.RemoteIP().String()

		// Get current count
		count, err := m.repo.GetRequestCount(ctx, ip, m.window)
		if err != nil {
			m.logger.Error().Err(err).Msg("rate limit check failed")
			next(ctx)
			return
		}

		// Check limit
		if count >= m.limit {
			writeError(ctx, fasthttp.StatusTooManyRequests, model.ErrRateLimited, "Too many requests")
			return
		}

		// Increment count
		if err := m.repo.IncrementRequestCount(ctx, ip); err != nil {
			m.logger.Error().Err(err).Msg("rate limit increment failed")
		}

		next(ctx)
	}
}

// writeError writes an error response.
func writeError(ctx *fasthttp.RequestCtx, code int, errType, message string) {
	ctx.SetStatusCode(code)
	ctx.SetContentType("application/json")
	resp := model.NewErrorResponse(code, errType, message, nil)
	writeJSON(ctx, resp)
}

// writeJSON writes a JSON response.
func writeJSON(ctx *fasthttp.RequestCtx, v interface{}) {
	data, _ := json.Marshal(v)
	ctx.SetBody(data)
}
