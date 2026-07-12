package handler

import (
	"github.com/valyala/fasthttp"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/rs/zerolog"
)

// SystemHandler handles HTTP requests for system operations.
type SystemHandler struct {
	service service.MonitorService
	logger  *zerolog.Logger
}

// NewSystemHandler creates a new SystemHandler.
func NewSystemHandler(svc service.MonitorService, logger *zerolog.Logger) *SystemHandler {
	return &SystemHandler{
		service: svc,
		logger:  logger,
	}
}

// Info handles GET /api/v1/system/info.
func (h *SystemHandler) Info(ctx *fasthttp.RequestCtx) {
	info, err := h.service.GetSystemInfo(ctx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "System info retrieved", info)
}

// Services handles GET /api/v1/system/services.
func (h *SystemHandler) Services(ctx *fasthttp.RequestCtx) {
	statuses, err := h.service.GetServiceStatus(ctx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Services retrieved", statuses)
}
