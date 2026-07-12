package router

import (
	"github.com/fasthttp/router"
	"github.com/valyala/fasthttp"
	"github.com/risqinf/autoscript-api/internal/handler"
	"github.com/risqinf/autoscript-api/internal/middleware"
)

// Router manages HTTP routes and middleware.
type Router struct {
	router      *router.Router
	authMw      *middleware.AuthMiddleware
	loggerMw    *middleware.LoggerMiddleware
	rateLimitMw *middleware.RateLimiter
}

// New creates a new Router.
func New(
	authMw *middleware.AuthMiddleware,
	loggerMw *middleware.LoggerMiddleware,
	rateLimitMw *middleware.RateLimiter,
) *Router {
	return &Router{
		router:      router.New(),
		authMw:      authMw,
		loggerMw:    loggerMw,
		rateLimitMw: rateLimitMw,
	}
}

// chainMiddleware chains multiple middleware functions.
func chainMiddleware(handler fasthttp.RequestHandler, middlewares ...func(fasthttp.RequestHandler) fasthttp.RequestHandler) fasthttp.RequestHandler {
	for i := len(middlewares) - 1; i >= 0; i-- {
		handler = middlewares[i](handler)
	}
	return handler
}

// RegisterAccountRoutes registers account-related routes.
func (r *Router) RegisterAccountRoutes(h *handler.AccountHandler) {
	// Public routes (no auth)
	r.router.GET("/api/v1/health", h.Health)

	// Protected routes (with auth)
	protected := func(handler fasthttp.RequestHandler) fasthttp.RequestHandler {
		return chainMiddleware(handler, r.loggerMw.Handle, r.authMw.Handle, r.rateLimitMw.Handle)
	}

	// Accounts
	r.router.POST("/api/v1/accounts/{protocol}", protected(h.Create))
	r.router.GET("/api/v1/accounts/{protocol}", protected(h.List))
	r.router.GET("/api/v1/accounts/{protocol}/{username}", protected(h.Get))
	r.router.PUT("/api/v1/accounts/{protocol}/{username}", protected(h.Update))
	r.router.DELETE("/api/v1/accounts/{protocol}/{username}", protected(h.Delete))
	r.router.POST("/api/v1/accounts/{protocol}/{username}/renew", protected(h.Renew))
	r.router.POST("/api/v1/accounts/{protocol}/{username}/recovery", protected(h.Recover))

	// Trials
	r.router.POST("/api/v1/trials/{protocol}", protected(h.CreateTrial))

	// Config
	r.router.GET("/api/v1/config/{protocol}/{username}", protected(h.GetConfig))
	r.router.GET("/api/v1/config/openvpn/{username}", protected(h.GetOpenVPNConfig))
}

// RegisterMonitorRoutes registers monitoring routes.
func (r *Router) RegisterMonitorRoutes(h *handler.MonitorHandler) {
	protected := func(handler fasthttp.RequestHandler) fasthttp.RequestHandler {
		return chainMiddleware(handler, r.loggerMw.Handle, r.authMw.Handle)
	}

	r.router.GET("/api/v1/status", protected(h.Status))
	r.router.GET("/api/v1/monitor/{protocol}", protected(h.Monitor))
	r.router.GET("/api/v1/bandwidth", protected(h.Bandwidth))
}

// RegisterSystemRoutes registers system routes.
func (r *Router) RegisterSystemRoutes(h *handler.SystemHandler) {
	protected := func(handler fasthttp.RequestHandler) fasthttp.RequestHandler {
		return chainMiddleware(handler, r.loggerMw.Handle, r.authMw.Handle)
	}

	r.router.GET("/api/v1/system/info", protected(h.Info))
	r.router.GET("/api/v1/system/services", protected(h.Services))
}

// Server creates a fasthttp.Server.
func (r *Router) Server(addr string) *fasthttp.Server {
	return &fasthttp.Server{
		Handler:            r.router.Handler,
		ReadBufferSize:     16384,
		WriteBufferSize:    16384,
		MaxRequestBodySize: 1 << 20, // 1MB
	}
}
