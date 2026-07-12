package handler

import (
	"encoding/json"
	"strconv"

	"github.com/valyala/fasthttp"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
)

// AccountHandler handles HTTP requests for account operations.
type AccountHandler struct {
	service   service.AccountService
	xray      service.XrayService
	validator *validator.Validator
	logger    *zerolog.Logger
}

// NewAccountHandler creates a new AccountHandler.
func NewAccountHandler(
	svc service.AccountService,
	xray service.XrayService,
	val *validator.Validator,
	logger *zerolog.Logger,
) *AccountHandler {
	return &AccountHandler{
		service:   svc,
		xray:      xray,
		validator: val,
		logger:    logger,
	}
}

// getUserValue safely extracts a string from ctx.UserValue.
func getUserValue(ctx *fasthttp.RequestCtx, key string) string {
	v, ok := ctx.UserValue(key).(string)
	if !ok {
		return ""
	}
	return v
}

// Create handles POST /api/v1/accounts/{protocol}.
func (h *AccountHandler) Create(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")

	if !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	var req model.CreateAccountRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid request body")
		return
	}

	if details := h.validator.ValidateCreateAccount(protocol, &req); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	account, err := h.service.CreateAccount(ctx, protocol, &req)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeCreated(ctx, "Account created successfully", account)
}

// Get handles GET /api/v1/accounts/{protocol}/{username}.
func (h *AccountHandler) Get(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")

	account, err := h.service.GetAccount(ctx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account retrieved successfully", account)
}

// List handles GET /api/v1/accounts/{protocol}.
func (h *AccountHandler) List(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")

	// Parse pagination
	page, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("page")))
	perPage, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("per_page")))

	if page < 1 {
		page = 1
	}
	if perPage < 1 || perPage > 100 {
		perPage = 20
	}

	accounts, total, err := h.service.ListAccounts(ctx, protocol, page, perPage)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccessWithMeta(ctx, "Accounts retrieved successfully", accounts, &model.Meta{
		Total:   total,
		Page:    page,
		PerPage: perPage,
	})
}

// Update handles PUT /api/v1/accounts/{protocol}/{username}.
func (h *AccountHandler) Update(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")

	var req model.CreateAccountRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid request body")
		return
	}

	account, err := h.service.UpdateAccount(ctx, protocol, username, &req)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account updated successfully", account)
}

// Delete handles DELETE /api/v1/accounts/{protocol}/{username}.
func (h *AccountHandler) Delete(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")

	if err := h.service.DeleteAccount(ctx, protocol, username); err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account deleted successfully", nil)
}

// Renew handles POST /api/v1/accounts/{protocol}/{username}/renew.
func (h *AccountHandler) Renew(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")

	var req model.RenewAccountRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid request body")
		return
	}

	if details := h.validator.ValidateRenew(&req); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	account, err := h.service.RenewAccount(ctx, protocol, username, req.Days)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account renewed successfully", account)
}

// Recover handles POST /api/v1/accounts/{protocol}/{username}/recovery.
func (h *AccountHandler) Recover(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")

	if err := h.service.RecoverAccount(ctx, protocol, username); err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account recovered successfully", nil)
}

// CreateTrial handles POST /api/v1/trials/{protocol}.
func (h *AccountHandler) CreateTrial(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")

	if !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	var req model.TrialRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid request body")
		return
	}

	if details := h.validator.ValidateTrial(protocol, &req); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	// Parse duration
	days := parseDurationToDays(req.Duration)
	if days == 0 {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid duration")
		return
	}

	// Generate trial username
	trialUser := "trial_" + generateRandomString(6)
	trialPass := generateRandomString(10)

	createReq := &model.CreateAccountRequest{
		Username: trialUser,
		Password: trialPass,
		Secret:   "", // Will be auto-generated for xray protocols
		Quota:    10, // 10GB default quota
		LimitIP:  2,  // 2 IP default limit
		Days:     days,
	}

	account, err := h.service.CreateAccount(ctx, protocol, createReq)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	// Generate config link
	link, err := h.xray.GetConfigLink(ctx, protocol, account.Username, account.Secret, "")
	if err != nil {
		h.logger.Warn().Err(err).Msg("failed to generate config link")
	}

	writeCreated(ctx, "Trial account created successfully", map[string]interface{}{
		"account": account,
		"config":  link,
	})
}

// GetConfig handles GET /api/v1/config/{protocol}/{username}.
func (h *AccountHandler) GetConfig(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")

	account, err := h.service.GetAccount(ctx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	domain := string(ctx.QueryArgs().Peek("domain"))
	if domain == "" {
		domain = "localhost"
	}

	link, err := h.xray.GetConfigLink(ctx, protocol, account.Username, account.Secret, domain)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Config retrieved successfully", link)
}

// GetOpenVPNConfig handles GET /api/v1/config/openvpn/{username}.
func (h *AccountHandler) GetOpenVPNConfig(ctx *fasthttp.RequestCtx) {
	username := getUserValue(ctx, "username")

	// Verify account exists
	_, err := h.service.GetAccount(ctx, "ssh", username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	config, err := h.xray.GetOpenVPNConfig(ctx, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	// Sanitize filename
	safeFilename := sanitizeFilename(username)

	// Set headers for file download
	ctx.SetContentType("application/x-openvpn-profile")
	ctx.Response.Header.Set("Content-Disposition", "attachment; filename=\""+safeFilename+".ovpn\"")
	ctx.SetBodyString(config)
}

// Health handles GET /api/v1/health.
func (h *AccountHandler) Health(ctx *fasthttp.RequestCtx) {
	writeSuccess(ctx, fasthttp.StatusOK, "Service is healthy", map[string]string{
		"status": "ok",
	})
}
