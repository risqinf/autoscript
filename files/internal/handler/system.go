package handler

import (
	"strconv"

	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
	"github.com/valyala/fasthttp"
)

// SystemHandler handles HTTP requests for system info, service management, Rocky optimization, and audit logs.
type SystemHandler struct {
	service    service.MonitorService
	accountSvc service.AccountService
	xraySvc    service.XrayService
	validator  *validator.Validator
	logger     *zerolog.Logger
}

// NewSystemHandler creates a new SystemHandler.
func NewSystemHandler(svc service.MonitorService, logger *zerolog.Logger) *SystemHandler {
	return &SystemHandler{
		service:   svc,
		validator: validator.New(),
		logger:    logger,
	}
}

// NewSystemHandlerFull creates a SystemHandler wired with AccountService and XrayService.
func NewSystemHandlerFull(
	svc service.MonitorService,
	accountSvc service.AccountService,
	xraySvc service.XrayService,
	val *validator.Validator,
	logger *zerolog.Logger,
) *SystemHandler {
	if val == nil {
		val = validator.New()
	}
	return &SystemHandler{
		service:    svc,
		accountSvc: accountSvc,
		xraySvc:    xraySvc,
		validator:  val,
		logger:     logger,
	}
}

// Info handles GET /api/system/info.
func (h *SystemHandler) Info(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	info, err := h.service.GetSystemInfo(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "System info retrieved", info)
}

// Services handles GET /api/system/services.
func (h *SystemHandler) Services(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	statuses, err := h.service.GetServiceStatus(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Services retrieved", statuses)
}

// ServiceAction handles POST /api/system/services/{service}/{action}.
func (h *SystemHandler) ServiceAction(ctx *fasthttp.RequestCtx) {
	svcName := getUserValue(ctx, "service")
	action := getUserValue(ctx, "action")

	if !h.validator.IsValidServiceAction(svcName, action) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Disallowed service name or action (allowed actions: start, stop, restart)")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	if err := h.service.ControlService(opCtx, svcName, action); err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Service action executed successfully", map[string]string{
		"service": svcName,
		"action":  action,
	})
}

// Ports handles GET /api/system/ports.
func (h *SystemHandler) Ports(ctx *fasthttp.RequestCtx) {
	var ports model.PortInfo
	if h.xraySvc != nil {
		ports = h.xraySvc.GetServerPorts()
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Server port matrix retrieved", ports)
}

// SlowDNS handles GET /api/system/slowdns.
func (h *SystemHandler) SlowDNS(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	status, err := h.service.GetSlowDNSInfo(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "SlowDNS info retrieved", status)
}

// Optimize handles POST /api/system/optimize.
func (h *SystemHandler) Optimize(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	res, err := h.service.RunRockyOptimization(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Rocky Linux optimization and firewall healing executed", res)
}

// AuditLogs handles GET /api/system/audit-logs.
func (h *SystemHandler) AuditLogs(ctx *fasthttp.RequestCtx) {
	if h.accountSvc == nil {
		writeSuccess(ctx, fasthttp.StatusOK, "Audit logs retrieved", []model.AuditLogEntry{})
		return
	}
	limit, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("limit")))
	if limit <= 0 || limit > 500 {
		limit = 100
	}

	opCtx, cancel := opContext()
	defer cancel()

	logs, err := h.accountSvc.GetAuditLogs(opCtx, limit)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Audit logs retrieved", logs)
}
