package handler

import (
	"github.com/valyala/fasthttp"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/rs/zerolog"
)

// MonitorHandler handles HTTP requests for monitoring operations.
type MonitorHandler struct {
	service service.MonitorService
	logger  *zerolog.Logger
}

// NewMonitorHandler creates a new MonitorHandler.
func NewMonitorHandler(svc service.MonitorService, logger *zerolog.Logger) *MonitorHandler {
	return &MonitorHandler{
		service: svc,
		logger:  logger,
	}
}

// Status handles GET /api/v1/status.
func (h *MonitorHandler) Status(ctx *fasthttp.RequestCtx) {
	statuses, err := h.service.GetServiceStatus(ctx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Service status retrieved", statuses)
}

// Monitor handles GET /api/v1/monitor/{protocol}.
func (h *MonitorHandler) Monitor(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")

	entries, err := h.service.GetMonitorEntries(ctx, protocol)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Monitor data retrieved", entries)
}

// Bandwidth handles GET /api/v1/bandwidth.
func (h *MonitorHandler) Bandwidth(ctx *fasthttp.RequestCtx) {
	// TODO: Implement bandwidth monitoring via vnstat
	writeSuccess(ctx, fasthttp.StatusOK, "Bandwidth monitoring", map[string]interface{}{
		"note": "Bandwidth monitoring via vnstat - implementation pending",
	})
}
