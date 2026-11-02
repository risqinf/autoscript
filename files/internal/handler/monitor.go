package handler

import (
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
	"github.com/valyala/fasthttp"
)

// MonitorHandler handles HTTP requests for live session monitoring, accessed apps/domains, ISP/GeoIP, quota, and bandwidth.
type MonitorHandler struct {
	service   service.MonitorService
	validator *validator.Validator
	logger    *zerolog.Logger
}

// NewMonitorHandler creates a new MonitorHandler.
func NewMonitorHandler(svc service.MonitorService, logger *zerolog.Logger) *MonitorHandler {
	return &MonitorHandler{
		service:   svc,
		validator: validator.New(),
		logger:    logger,
	}
}

// Status handles GET /api/status.
func (h *MonitorHandler) Status(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	statuses, err := h.service.GetServiceStatus(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Service status retrieved", statuses)
}

// UnifiedMonitor handles GET /api/monitor (live sessions across ALL protocols with Apps/Domains, Transport, ISP & GeoIP).
func (h *MonitorHandler) UnifiedMonitor(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	rep, err := h.service.GetUnifiedMonitor(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Unified live monitor retrieved", rep)
}

// Monitor handles GET /api/monitor/{protocol}.
func (h *MonitorHandler) Monitor(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	if protocol != "all" && !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	entries, err := h.service.GetMonitorEntries(opCtx, protocol)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	if entries == nil {
		entries = []model.MonitorEntry{}
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Monitor data retrieved", entries)
}

// UserActivity handles GET /api/monitor/{protocol}/{username} and GET /api/monitor/{protocol}/{username}/activity.
func (h *MonitorHandler) UserActivity(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	entry, err := h.service.GetUserActivity(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "User live session & app telemetry retrieved", entry)
}

// QuotaByProtocol handles GET /api/quota/{protocol} (when protocol == "ssh", returns full SSH All-Protocol Quota breakdown!).
func (h *MonitorHandler) QuotaByProtocol(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	opCtx, cancel := opContext()
	defer cancel()

	if protocol == "ssh" {
		rep, err := h.service.GetSSHAllProtocolQuota(opCtx)
		if err != nil {
			handleServiceError(ctx, err)
			return
		}
		writeSuccess(ctx, fasthttp.StatusOK, "SSH All-Protocol quota usage retrieved (OpenSSH, Dropbear, SSH SSL/TLS, SSH-WS, SlowDNS, OpenVPN)", rep)
		return
	}

	if !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	list, err := h.service.GetProtocolQuotaList(opCtx, protocol)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Protocol quota usage retrieved", list)
}

// QuotaByUser handles GET /api/quota/{protocol}/{username} (when protocol == "ssh", returns detailed 6-subprotocol SSH breakdown!).
func (h *MonitorHandler) QuotaByUser(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	if protocol == "ssh" {
		detail, err := h.service.GetSSHUserQuota(opCtx, username)
		if err != nil {
			handleServiceError(ctx, err)
			return
		}
		writeSuccess(ctx, fasthttp.StatusOK, "SSH All-Protocol user quota retrieved", detail)
		return
	}

	detail, err := h.service.GetUserQuota(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "User quota retrieved", detail)
}

// Bandwidth handles GET /api/bandwidth (vnstat --json + /proc/net/dev fallback).
func (h *MonitorHandler) Bandwidth(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	rep, err := h.service.GetBandwidth(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Bandwidth statistics retrieved", rep)
}
