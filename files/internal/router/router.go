package router

import (
	"encoding/json"
	"time"

	"github.com/fasthttp/router"
	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/handler"
	"github.com/risqinf/autoscript-api/internal/middleware"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/valyala/fasthttp"
)

// Router manages HTTP routes and middleware chains.
type Router struct {
	router      *router.Router
	authMw      *middleware.AuthMiddleware
	loggerMw    *middleware.LoggerMiddleware
	rateLimitMw *middleware.RateLimiter
	cfg         *config.Config
}

// New creates a new Router.
func New(
	authMw *middleware.AuthMiddleware,
	loggerMw *middleware.LoggerMiddleware,
	rateLimitMw *middleware.RateLimiter,
) *Router {
	return NewWithConfig(authMw, loggerMw, rateLimitMw, nil)
}

// NewWithConfig creates a new Router with explicit server tuning configuration.
func NewWithConfig(
	authMw *middleware.AuthMiddleware,
	loggerMw *middleware.LoggerMiddleware,
	rateLimitMw *middleware.RateLimiter,
	cfg *config.Config,
) *Router {
	rt := router.New()
	rt.NotFound = func(ctx *fasthttp.RequestCtx) {
		ctx.SetStatusCode(fasthttp.StatusNotFound)
		ctx.SetContentType("application/json")
		b, _ := json.Marshal(model.NewNotFoundError("Endpoint not found"))
		ctx.SetBody(b)
		if authMw != nil {
			authMw.SignAndHardenResponse(ctx)
		}
	}
	rt.MethodNotAllowed = func(ctx *fasthttp.RequestCtx) {
		ctx.SetStatusCode(fasthttp.StatusMethodNotAllowed)
		ctx.SetContentType("application/json")
		b, _ := json.Marshal(model.NewErrorResponse(fasthttp.StatusMethodNotAllowed, model.ErrValidation, "HTTP method not allowed", nil))
		ctx.SetBody(b)
		if authMw != nil {
			authMw.SignAndHardenResponse(ctx)
		}
	}

	return &Router{
		router:      rt,
		authMw:      authMw,
		loggerMw:    loggerMw,
		rateLimitMw: rateLimitMw,
		cfg:         cfg,
	}
}

func chainMiddleware(h fasthttp.RequestHandler, middlewares ...func(fasthttp.RequestHandler) fasthttp.RequestHandler) fasthttp.RequestHandler {
	for i := len(middlewares) - 1; i >= 0; i-- {
		h = middlewares[i](h)
	}
	return h
}

func (r *Router) protected(h fasthttp.RequestHandler) fasthttp.RequestHandler {
	return chainMiddleware(h, r.authMw.SignResponseMiddleware, r.loggerMw.Handle, r.authMw.Handle, r.rateLimitMw.Handle)
}

func (r *Router) public(h fasthttp.RequestHandler) fasthttp.RequestHandler {
	return chainMiddleware(h, r.authMw.SignResponseMiddleware, r.loggerMw.Handle, r.rateLimitMw.Handle)
}

// RegisterAccountRoutes registers strictly standard REST endpoints (POST /api/accounts/{protocol} handles both 1 and 1,000 accounts seamlessly).
func (r *Router) RegisterAccountRoutes(h *handler.AccountHandler) {
	for _, prefix := range []string{"/api", "/api/v1"} {
		// Public health endpoint (includes server_time for client clock sync)
		r.router.GET(prefix+"/health", r.public(h.Health))

		// Cryptographic verification diagnostic endpoint
		r.router.GET(prefix+"/auth/verify", r.protected(h.AuthVerify))

		// Cross-protocol overview & maintenance
		r.router.GET(prefix+"/accounts", r.protected(h.Overview))
		r.router.POST(prefix+"/system/cleanup", r.protected(h.Cleanup))

		// Standard Account Collection CRUD (POST creates 1 OR up to 1,000 accounts in 1 request; PUT/DELETE operate on batch lists)
		r.router.POST(prefix+"/accounts/{protocol}", r.protected(h.Create))
		r.router.GET(prefix+"/accounts/{protocol}", r.protected(h.List))
		r.router.PUT(prefix+"/accounts/{protocol}", r.protected(h.UpdateCollection))
		r.router.DELETE(prefix+"/accounts/{protocol}", r.protected(h.DeleteCollection))

		// Standard Single Account Item CRUD + Actions
		r.router.GET(prefix+"/accounts/{protocol}/{username}", r.protected(h.Get))
		r.router.PUT(prefix+"/accounts/{protocol}/{username}", r.protected(h.Update))
		r.router.DELETE(prefix+"/accounts/{protocol}/{username}", r.protected(h.Delete))
		r.router.POST(prefix+"/accounts/{protocol}/{username}/renew", r.protected(h.Renew))
		r.router.POST(prefix+"/accounts/{protocol}/{username}/recovery", r.protected(h.Recover))
		r.router.POST(prefix+"/accounts/{protocol}/{username}/suspend", r.protected(h.Suspend))
		r.router.POST(prefix+"/accounts/{protocol}/{username}/unsuspend", r.protected(h.Unsuspend))
		r.router.POST(prefix+"/accounts/{protocol}/{username}/reset-quota", r.protected(h.ResetQuota))
		r.router.POST(prefix+"/accounts/{protocol}/{username}/kick", r.protected(h.Kick))

		// Standard Trials Endpoint (handles 1 single trial OR `count > 1` bulk trials seamlessly)
		r.router.POST(prefix+"/trials/{protocol}", r.protected(h.CreateTrial))

		// Connection Configs (GetConfig also serves /config/openvpn/{username} when protocol == "openvpn")
		r.router.GET(prefix+"/config/{protocol}/{username}", r.protected(h.GetConfig))
	}
}

// RegisterMonitorRoutes registers live session, app/domain, ISP/GeoIP, SSH All-Protocol quota, and bandwidth routes.
func (r *Router) RegisterMonitorRoutes(h *handler.MonitorHandler) {
	for _, prefix := range []string{"/api", "/api/v1"} {
		r.router.GET(prefix+"/status", r.protected(h.Status))
		r.router.GET(prefix+"/bandwidth", r.protected(h.Bandwidth))

		// Live session monitor + accessed apps/domains + protocol/transport + ISP + GeoIP
		r.router.GET(prefix+"/monitor", r.protected(h.UnifiedMonitor))
		r.router.GET(prefix+"/monitor/{protocol}", r.protected(h.Monitor))
		r.router.GET(prefix+"/monitor/{protocol}/{username}", r.protected(h.UserActivity))
		r.router.GET(prefix+"/monitor/{protocol}/{username}/activity", r.protected(h.UserActivity))

		// SSH All-Protocol Quota (/api/quota/ssh, /api/quota/ssh/{username}) & Multi-Protocol Quota
		r.router.GET(prefix+"/quota/{protocol}", r.protected(h.QuotaByProtocol))
		r.router.GET(prefix+"/quota/{protocol}/{username}", r.protected(h.QuotaByUser))
	}
}

// RegisterSystemRoutes registers system info, service management, Rocky optimization, and audit routes.
func (r *Router) RegisterSystemRoutes(h *handler.SystemHandler) {
	for _, prefix := range []string{"/api", "/api/v1"} {
		r.router.GET(prefix+"/system/info", r.protected(h.Info))
		r.router.GET(prefix+"/system/services", r.protected(h.Services))
		r.router.POST(prefix+"/system/services/{service}/{action}", r.protected(h.ServiceAction))
		r.router.GET(prefix+"/system/ports", r.protected(h.Ports))
		r.router.GET(prefix+"/system/slowdns", r.protected(h.SlowDNS))
		r.router.POST(prefix+"/system/optimize", r.protected(h.Optimize))
		r.router.GET(prefix+"/system/audit-logs", r.protected(h.AuditLogs))
	}
}

// Handler returns the underlying fasthttp.RequestHandler (useful for zero-network unit/benchmark tests).
func (r *Router) Handler() fasthttp.RequestHandler {
	return r.router.Handler
}

// Server creates a production-hardened, million-request tuned fasthttp.Server.
func (r *Router) Server(addr string) *fasthttp.Server {
	maxConc := 262144
	if r.cfg != nil && r.cfg.MaxConcurrency > 0 {
		maxConc = r.cfg.MaxConcurrency
	}

	return &fasthttp.Server{
		Handler:               r.router.Handler,
		Concurrency:           maxConc,
		ReduceMemoryUsage:     true,
		NoDefaultServerHeader: true,
		ReadBufferSize:        16384,
		WriteBufferSize:       16384,
		MaxRequestBodySize:    8 << 20, // 8MB max body (supports 1,000-item bulk JSON while blocking DoS)
		ReadTimeout:           15 * time.Second,
		WriteTimeout:          30 * time.Second,
		IdleTimeout:           60 * time.Second,
	}
}
