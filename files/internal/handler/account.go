package handler

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/cache"
	"github.com/risqinf/autoscript-api/internal/config"
	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/risqinf/autoscript-api/internal/service"
	"github.com/risqinf/autoscript-api/internal/validator"
	"github.com/rs/zerolog"
	"github.com/valyala/fasthttp"
)

// AccountHandler handles HTTP requests for standard single & Flash-Sale bulk account operations.
type AccountHandler struct {
	service   service.AccountService
	xray      service.XrayService
	validator *validator.Validator
	cfg       *config.Config
	idem      *cache.IdempotencyStore
	logger    *zerolog.Logger
}

// NewAccountHandler creates a new AccountHandler.
func NewAccountHandler(
	svc service.AccountService,
	xray service.XrayService,
	val *validator.Validator,
	logger *zerolog.Logger,
) *AccountHandler {
	return NewAccountHandlerWithConfig(svc, xray, val, nil, logger)
}

// NewAccountHandlerWithConfig creates a new AccountHandler with explicit Config and IdempotencyStore.
func NewAccountHandlerWithConfig(
	svc service.AccountService,
	xray service.XrayService,
	val *validator.Validator,
	cfg *config.Config,
	logger *zerolog.Logger,
) *AccountHandler {
	return &AccountHandler{
		service:   svc,
		xray:      xray,
		validator: val,
		cfg:       cfg,
		idem:      cache.NewIdempotencyStore(15 * time.Minute),
		logger:    logger,
	}
}

func (h *AccountHandler) maxBulk() int {
	if h.cfg != nil && h.cfg.MaxBulkSize > 0 {
		return h.cfg.MaxBulkSize
	}
	return 1000
}

// Health handles GET /api/health (public).
func (h *AccountHandler) Health(ctx *fasthttp.RequestCtx) {
	secMode := "strict"
	if h.cfg != nil && h.cfg.SecurityMode != "" {
		secMode = h.cfg.SecurityMode
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Service is healthy", map[string]interface{}{
		"status":        "ok",
		"version":       service.AppVersion,
		"server_time":   time.Now().Unix(),
		"security_mode": secMode,
	})
}

// AuthVerify handles GET /api/auth/verify (returns verified 5-layer SHA-256 report).
func (h *AccountHandler) AuthVerify(ctx *fasthttp.RequestCtx) {
	writeSuccess(ctx, fasthttp.StatusOK, "Multi-layer SHA-256 verification succeeded", map[string]interface{}{
		"authenticated": true,
		"version":       service.AppVersion,
		"server_time":   time.Now().Unix(),
		"verification":  ctx.UserValue("auth_result"),
	})
}

// Overview handles GET /api/accounts (cross-protocol summary & search).
func (h *AccountHandler) Overview(ctx *fasthttp.RequestCtx) {
	proto := strings.TrimSpace(string(ctx.QueryArgs().Peek("protocol")))
	status := strings.TrimSpace(string(ctx.QueryArgs().Peek("status")))
	search := strings.TrimSpace(string(ctx.QueryArgs().Peek("search")))
	page, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("page")))
	perPage, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("per_page")))

	if page < 1 {
		page = 1
	}
	if perPage < 1 || perPage > 1000 {
		perPage = 50
	}

	opCtx, cancel := opContext()
	defer cancel()

	summaries, err := h.service.GetAccountsSummary(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	accounts, total, err := h.service.ListAccountsFiltered(opCtx, proto, status, search, page, perPage)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccessWithMeta(ctx, "Accounts overview retrieved successfully", map[string]interface{}{
		"summary":  summaries,
		"accounts": accounts,
	}, &model.Meta{
		Total:   total,
		Page:    page,
		PerPage: perPage,
	})
}

// Create handles POST /api/accounts/{protocol} (and POST /api/accounts with "protocol" in JSON body) seamlessly for BOTH:
//  1. Single account creation (100% compatible standard payload: {"username":"...", "days":30, ...})
//  2. Flash-Sale bulk creation of up to 1,000 accounts in 1 request (via `count > 1`, `accounts: [...]`, or top-level JSON array `[...]`).
func (h *AccountHandler) Create(ctx *fasthttp.RequestCtx) {
	protocol := strings.ToLower(strings.TrimSpace(getUserValue(ctx, "protocol")))
	if protocol == "" {
		protocol = strings.ToLower(strings.TrimSpace(string(ctx.QueryArgs().Peek("protocol"))))
	}
	if protocol == "cleanup" {
		h.Cleanup(ctx)
		return
	}

	rawBody := bytes.TrimSpace(ctx.PostBody())
	if len(rawBody) == 0 {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Empty JSON request body")
		return
	}

	if protocol == "" && rawBody[0] == '{' {
		var protoProbe struct {
			Protocol string `json:"protocol"`
		}
		if json.Unmarshal(rawBody, &protoProbe) == nil {
			protocol = strings.ToLower(strings.TrimSpace(protoProbe.Protocol))
		}
	}

	if !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid or missing protocol (expected: ssh, vless, vmess, trojan, noobz)")
		return
	}

	idemKey := strings.TrimSpace(string(ctx.Request.Header.Peek("X-Idempotency-Key")))
	idemScope := "create:" + protocol + ":" + idemKey
	if idemKey != "" {
		if cached, ok := h.idem.Get(idemScope); ok {
			ctx.SetStatusCode(cached.Status)
			ctx.SetContentType("application/json")
			ctx.Response.Header.Set("X-Idempotent-Replay", "true")
			ctx.SetBody(cached.Payload)
			return
		}
	}

	// Case 1: Top-level JSON Array `[ {...}, {...} ]` -> Bulk Create
	if rawBody[0] == '[' {
		var arr []model.CreateAccountRequest
		if err := json.Unmarshal(rawBody, &arr); err != nil {
			writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON array in request body")
			return
		}
		bulkReq := model.BulkCreateRequest{
			Protocol: protocol,
			Accounts: arr,
		}
		if qInc := strings.TrimSpace(string(ctx.QueryArgs().Peek("include_config"))); qInc == "false" {
			f := false
			bulkReq.IncludeConfig = &f
		}
		h.executeBulkCreate(ctx, protocol, &bulkReq, idemKey, idemScope)
		return
	}

	// Unmarshal object payload (supports both single CreateAccountRequest and BulkCreateRequest fields)
	var bulkReq model.BulkCreateRequest
	if err := json.Unmarshal(rawBody, &bulkReq); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
		return
	}

	// Case 2: Bulk / Flash-Sale mode (`accounts` array provided OR `count > 1`)
	if len(bulkReq.Accounts) > 0 || bulkReq.Count > 1 {
		bulkReq.Protocol = protocol
		if bulkReq.Prefix == "" && bulkReq.Username != "" {
			bulkReq.Prefix = bulkReq.Username
		}
		if bulkReq.IncludeConfig == nil {
			if qInc := strings.TrimSpace(string(ctx.QueryArgs().Peek("include_config"))); qInc == "false" {
				f := false
				bulkReq.IncludeConfig = &f
			}
		}
		h.executeBulkCreate(ctx, protocol, &bulkReq, idemKey, idemScope)
		return
	}

	// Case 3: Standard Single Account Creation (100% backward-compatible!)
	singleReq := model.CreateAccountRequest{
		Username: bulkReq.Username,
		Password: bulkReq.Password,
		Secret:   bulkReq.Secret,
		Quota:    bulkReq.Quota,
		LimitIP:  bulkReq.LimitIP,
		Days:     bulkReq.Days,
		Duration: bulkReq.Duration,
		Note:     bulkReq.Note,
	}
	if singleReq.Username == "" && bulkReq.Prefix != "" {
		singleReq.Username = bulkReq.Prefix + generateRandomString(6)
		if (protocol == "ssh" || protocol == "noobz") && singleReq.Password == "" {
			singleReq.Password = generateRandomString(10)
		}
	}

	if details := h.validator.ValidateCreateAccount(protocol, &singleReq); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	account, err := h.service.CreateAccount(opCtx, protocol, &singleReq)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	includeCfg := string(ctx.QueryArgs().Peek("include_config")) == "true" ||
		(bulkReq.IncludeConfig != nil && *bulkReq.IncludeConfig)
	if includeCfg {
		link, _ := h.xray.GetConfigLink(opCtx, protocol, account.Username, account.Secret, "")
		writeCreated(ctx, "Account created successfully", map[string]interface{}{
			"account": account,
			"config":  link,
		})
	} else {
		writeCreated(ctx, "Account created successfully", account)
	}

	if idemKey != "" {
		h.idem.Set(idemScope, fasthttp.StatusCreated, ctx.Response.Body())
	}
}

func (h *AccountHandler) executeBulkCreate(
	ctx *fasthttp.RequestCtx,
	protocol string,
	req *model.BulkCreateRequest,
	idemKey string,
	idemScope string,
) {
	if details := h.validator.ValidateBulkCreate(protocol, req, h.maxBulk()); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	result, err := h.service.CreateBulkAccounts(opCtx, protocol, req)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	result.IdempotencyKey = idemKey

	writeCreated(ctx, "Accounts created successfully", result)
	if idemKey != "" {
		h.idem.Set(idemScope, fasthttp.StatusCreated, ctx.Response.Body())
	}
}

// DeleteCollection handles DELETE /api/accounts/{protocol} for batch deletion (`{"usernames": [...]}`).
func (h *AccountHandler) DeleteCollection(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	if !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	var req model.BulkDeleteRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
		return
	}
	if len(req.Usernames) == 0 || len(req.Usernames) > h.maxBulk() {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "usernames array must contain 1..1000 items")
		return
	}
	for _, u := range req.Usernames {
		if !h.validator.IsValidUsername(u) {
			writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid username in list: "+u)
			return
		}
	}

	opCtx, cancel := opContext()
	defer cancel()

	deleted, err := h.service.DeleteBulkAccounts(opCtx, protocol, req.Usernames)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Accounts deleted successfully", map[string]interface{}{
		"protocol":        protocol,
		"requested_count": len(req.Usernames),
		"deleted_count":   deleted,
	})
}

// UpdateCollection handles PUT /api/accounts/{protocol} for batch renewal (`{"usernames": [...], "days": 30}`).
func (h *AccountHandler) UpdateCollection(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	if !h.validator.IsValidProtocol(protocol) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	var req model.BulkRenewRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
		return
	}
	if len(req.Usernames) == 0 || len(req.Usernames) > h.maxBulk() {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "usernames array must contain 1..1000 items")
		return
	}
	if req.Days < 1 || req.Days > 3650 {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "days must be between 1 and 3650")
		return
	}
	for _, u := range req.Usernames {
		if !h.validator.IsValidUsername(u) {
			writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid username in list: "+u)
			return
		}
	}

	opCtx, cancel := opContext()
	defer cancel()

	updated, err := h.service.RenewBulkAccounts(opCtx, protocol, req.Usernames, req.Days)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Accounts renewed successfully", map[string]interface{}{
		"protocol":      protocol,
		"renewed_count": len(updated),
		"accounts":      updated,
	})
}

// Get handles GET /api/accounts/{protocol}/{username}.
func (h *AccountHandler) Get(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	account, err := h.service.GetAccount(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account retrieved successfully", account)
}

// List handles GET /api/accounts/{protocol}.
func (h *AccountHandler) List(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	if !h.validator.IsValidProtocol(protocol) && protocol != "all" {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
		return
	}

	page, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("page")))
	perPage, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("per_page")))
	status := strings.TrimSpace(string(ctx.QueryArgs().Peek("status")))
	search := strings.TrimSpace(string(ctx.QueryArgs().Peek("search")))

	if page < 1 {
		page = 1
	}
	if perPage < 1 || perPage > 1000 {
		perPage = 20
	}

	opCtx, cancel := opContext()
	defer cancel()

	accounts, total, err := h.service.ListAccountsFiltered(opCtx, protocol, status, search, page, perPage)
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

// Update handles PUT /api/accounts/{protocol}/{username}.
func (h *AccountHandler) Update(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	var req model.CreateAccountRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
		return
	}
	if req.Password != "" && !h.validator.IsValidPassword(req.Password) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid password format")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	account, err := h.service.UpdateAccount(opCtx, protocol, username, &req)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account updated successfully", account)
}

// Delete handles DELETE /api/accounts/{protocol}/{username} and POST /api/accounts/{protocol}/{username}/delete.
func (h *AccountHandler) Delete(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	if err := h.service.DeleteAccount(opCtx, protocol, username); err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account deleted successfully", map[string]interface{}{
		"protocol": protocol,
		"username": username,
		"deleted":  true,
	})
}

// DeleteAutoDetect handles DELETE /api/users/{username} and POST /api/users/{username}/delete
// by automatically detecting which protocol(s) the username belongs to and deleting cleanly.
func (h *AccountHandler) DeleteAutoDetect(ctx *fasthttp.RequestCtx) {
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid username")
		return
	}

	protoFilter := strings.ToLower(strings.TrimSpace(string(ctx.QueryArgs().Peek("protocol"))))
	if protoFilter == "" && len(ctx.PostBody()) > 0 {
		var body struct {
			Protocol string `json:"protocol"`
		}
		if json.Unmarshal(ctx.PostBody(), &body) == nil {
			protoFilter = strings.ToLower(strings.TrimSpace(body.Protocol))
		}
	}

	opCtx, cancel := opContext()
	defer cancel()

	if protoFilter != "" {
		if !h.validator.IsValidProtocol(protoFilter) {
			writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
			return
		}
		if err := h.service.DeleteAccount(opCtx, protoFilter, username); err != nil {
			handleServiceError(ctx, err)
			return
		}
		writeSuccess(ctx, fasthttp.StatusOK, "Account deleted successfully", map[string]interface{}{
			"username":          username,
			"deleted_protocols": []string{protoFilter},
		})
		return
	}

	deletedProtocols, err := h.service.DeleteUserAutoDetect(opCtx, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "User deleted across detected protocol(s)", map[string]interface{}{
		"username":          username,
		"deleted_protocols": deletedProtocols,
	})
}

// Renew handles POST /api/accounts/{protocol}/{username}/renew.
func (h *AccountHandler) Renew(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	var req model.RenewAccountRequest
	if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
		return
	}

	if details := h.validator.ValidateRenew(&req); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	account, err := h.service.RenewAccountWithOptions(opCtx, protocol, username, req.Days, req.ResetQuota)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account renewed successfully", account)
}

// RenewAutoDetect handles POST /api/users/{username}/renew by automatically detecting
// the user's protocol(s) and extending expiry (+ optional quota reset).
func (h *AccountHandler) RenewAutoDetect(ctx *fasthttp.RequestCtx) {
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid username")
		return
	}

	var body struct {
		Protocol   string `json:"protocol"`
		Days       int    `json:"days"`
		ResetQuota bool   `json:"reset_quota"`
	}
	if err := json.Unmarshal(ctx.PostBody(), &body); err != nil {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
		return
	}

	renewReq := model.RenewAccountRequest{
		Days:       body.Days,
		ResetQuota: body.ResetQuota,
	}
	if details := h.validator.ValidateRenew(&renewReq); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	protoFilter := strings.ToLower(strings.TrimSpace(body.Protocol))
	if protoFilter == "" {
		protoFilter = strings.ToLower(strings.TrimSpace(string(ctx.QueryArgs().Peek("protocol"))))
	}

	opCtx, cancel := opContext()
	defer cancel()

	if protoFilter != "" {
		if !h.validator.IsValidProtocol(protoFilter) {
			writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
			return
		}
		acc, err := h.service.RenewAccountWithOptions(opCtx, protoFilter, username, body.Days, body.ResetQuota)
		if err != nil {
			handleServiceError(ctx, err)
			return
		}
		writeSuccess(ctx, fasthttp.StatusOK, "Account renewed successfully", acc)
		return
	}

	renewed, err := h.service.RenewUserAutoDetect(opCtx, username, body.Days, body.ResetQuota)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	detected := make([]string, 0, len(renewed))
	outputs := make([]model.BulkAccountOutput, 0, len(renewed))
	for _, acc := range renewed {
		detected = append(detected, acc.Protocol)
		var cfgLink *model.ConfigLink
		if h.xray != nil {
			cfgLink, _ = h.xray.GetConfigLink(opCtx, acc.Protocol, acc.Username, acc.Secret, "")
		}
		outputs = append(outputs, model.BulkAccountOutput{
			Account: acc,
			Config:  cfgLink,
		})
	}

	writeSuccess(ctx, fasthttp.StatusOK, "User renewed across detected protocol(s)", map[string]interface{}{
		"username":           username,
		"days_added":         body.Days,
		"detected_protocols": detected,
		"accounts":           outputs,
	})
}

// Recover handles POST /api/accounts/{protocol}/{username}/recovery.
func (h *AccountHandler) Recover(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	if err := h.service.RecoverAccount(opCtx, protocol, username); err != nil {
		handleServiceError(ctx, err)
		return
	}

	acc, _ := h.service.GetAccount(opCtx, protocol, username)
	writeSuccess(ctx, fasthttp.StatusOK, "Account recovered successfully", acc)
}

// Suspend handles POST /api/accounts/{protocol}/{username}/suspend.
func (h *AccountHandler) Suspend(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	var body struct {
		Reason string `json:"reason"`
	}
	if len(ctx.PostBody()) > 0 {
		_ = json.Unmarshal(ctx.PostBody(), &body)
	}

	opCtx, cancel := opContext()
	defer cancel()

	acc, err := h.service.SuspendAccount(opCtx, protocol, username, body.Reason)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account suspended successfully", acc)
}

// Unsuspend handles POST /api/accounts/{protocol}/{username}/unsuspend.
func (h *AccountHandler) Unsuspend(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	acc, err := h.service.UnsuspendAccount(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account unsuspended successfully", acc)
}

// ResetQuota handles POST /api/accounts/{protocol}/{username}/reset-quota.
func (h *AccountHandler) ResetQuota(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	acc, err := h.service.ResetAccountQuota(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Account quota reset to 0", acc)
}

// Kick handles POST /api/accounts/{protocol}/{username}/kick.
func (h *AccountHandler) Kick(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	killed, err := h.service.KickAccount(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Active sessions disconnected", map[string]interface{}{
		"protocol":             protocol,
		"username":             username,
		"processes_terminated": killed,
	})
}

// Cleanup handles POST /api/system/cleanup and POST /api/accounts/cleanup.
func (h *AccountHandler) Cleanup(ctx *fasthttp.RequestCtx) {
	opCtx, cancel := opContext()
	defer cancel()

	affected, err := h.service.CleanupAccounts(opCtx)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}
	writeSuccess(ctx, fasthttp.StatusOK, "Expired and deleted accounts cleaned up", map[string]interface{}{
		"affected_records": affected,
	})
}

// CreateTrial handles POST /api/trials/{protocol} (and POST /api/trials with "protocol" in JSON body)
// for BOTH 1 single trial AND up to 1,000 bulk trials (`count > 1`)!
func (h *AccountHandler) CreateTrial(ctx *fasthttp.RequestCtx) {
	protocol := strings.ToLower(strings.TrimSpace(getUserValue(ctx, "protocol")))
	if protocol == "" {
		protocol = strings.ToLower(strings.TrimSpace(string(ctx.QueryArgs().Peek("protocol"))))
	}

	var req model.TrialRequest
	if len(ctx.PostBody()) > 0 {
		if err := json.Unmarshal(ctx.PostBody(), &req); err != nil {
			writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid JSON request body")
			return
		}
		if protocol == "" {
			var probe struct {
				Protocol string `json:"protocol"`
			}
			if json.Unmarshal(ctx.PostBody(), &probe) == nil {
				protocol = strings.ToLower(strings.TrimSpace(probe.Protocol))
			}
		}
	}
	if req.Duration == "" {
		req.Duration = "1h"
	}

	if details := h.validator.ValidateTrial(protocol, &req); len(details) > 0 {
		writeValidationError(ctx, "Validation failed", details)
		return
	}

	limitIP := req.LimitIP
	if limitIP == 0 {
		limitIP = 2
	}
	quota := req.Quota
	if quota == 0 {
		quota = 5
	}

	opCtx, cancel := opContext()
	defer cancel()

	// Bulk Trial Mode on the exact same standard POST /api/trials/{protocol} endpoint when count > 1
	if req.Count > 1 {
		pfx := req.Prefix
		if pfx == "" {
			pfx = "trial_"
		}
		bulkReq := &model.BulkCreateRequest{
			Protocol: protocol,
			Count:    req.Count,
			Prefix:   pfx,
			Quota:    quota,
			LimitIP:  limitIP,
			Days:     1,
			Duration: req.Duration,
			Note:     "trial:" + req.Duration,
		}
		res, err := h.service.CreateBulkAccounts(opCtx, protocol, bulkReq)
		if err != nil {
			handleServiceError(ctx, err)
			return
		}
		writeCreated(ctx, "Trial accounts created successfully", res)
		return
	}

	pfx := req.Prefix
	if pfx == "" {
		pfx = "trial_"
	}
	trialUser := pfx + generateRandomString(6)
	trialPass := generateRandomString(10)

	createReq := &model.CreateAccountRequest{
		Username: trialUser,
		Password: trialPass,
		Quota:    quota,
		LimitIP:  limitIP,
		Days:     1,
		Duration: req.Duration,
		Note:     "trial:" + req.Duration,
	}

	account, err := h.service.CreateAccount(opCtx, protocol, createReq)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	link, _ := h.xray.GetConfigLink(opCtx, protocol, account.Username, account.Secret, "")
	writeCreated(ctx, "Trial account created successfully", map[string]interface{}{
		"account": account,
		"config":  link,
	})
}

// GetConfig handles GET /api/config/{protocol}/{username} (and /api/config/openvpn/{username}).
func (h *AccountHandler) GetConfig(ctx *fasthttp.RequestCtx) {
	protocol := getUserValue(ctx, "protocol")
	if protocol == "openvpn" {
		h.GetOpenVPNConfig(ctx)
		return
	}
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidProtocol(protocol) || !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol or username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	account, err := h.service.GetAccount(opCtx, protocol, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	domain := strings.TrimSpace(string(ctx.QueryArgs().Peek("domain")))
	if domain != "" && !h.validator.IsValidDomain(domain) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid domain query parameter")
		return
	}

	link, err := h.xray.GetConfigLink(opCtx, protocol, account.Username, account.Secret, domain)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	writeSuccess(ctx, fasthttp.StatusOK, "Config retrieved successfully", link)
}

// GetOpenVPNConfig handles GET /api/config/openvpn/{username}.
func (h *AccountHandler) GetOpenVPNConfig(ctx *fasthttp.RequestCtx) {
	username := getUserValue(ctx, "username")
	if !h.validator.IsValidUsername(username) {
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid username")
		return
	}

	opCtx, cancel := opContext()
	defer cancel()

	if _, err := h.service.GetAccount(opCtx, "ssh", username); err != nil {
		handleServiceError(ctx, err)
		return
	}

	ovpnContent, err := h.xray.GetOpenVPNConfig(opCtx, username)
	if err != nil {
		handleServiceError(ctx, err)
		return
	}

	safeFilename := sanitizeFilename(username)
	ctx.SetStatusCode(fasthttp.StatusOK)
	ctx.SetContentType("application/x-openvpn-profile")
	ctx.Response.Header.Set("Content-Disposition", "attachment; filename=\""+safeFilename+".ovpn\"")
	ctx.SetBodyString(ovpnContent)
}
