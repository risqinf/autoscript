package handler

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/risqinf/autoscript-api/internal/model"
	"github.com/valyala/fasthttp"
)

// opContext creates a bounded standard Go context decoupled from fasthttp's pooled RequestCtx.
func opContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), 30*time.Second)
}

// writeJSON writes a JSON response.
func writeJSON(ctx *fasthttp.RequestCtx, statusCode int, v interface{}) {
	ctx.SetStatusCode(statusCode)
	ctx.SetContentType("application/json")
	data, _ := json.Marshal(v)
	ctx.SetBody(data)
}

// writeSuccess writes a success response.
func writeSuccess(ctx *fasthttp.RequestCtx, code int, message string, data interface{}) {
	writeJSON(ctx, code, model.NewSuccessResponse(code, message, data))
}

// writeSuccessWithMeta writes a success response with pagination.
func writeSuccessWithMeta(ctx *fasthttp.RequestCtx, message string, data interface{}, meta *model.Meta) {
	writeJSON(ctx, fasthttp.StatusOK, model.NewSuccessResponseWithMeta(fasthttp.StatusOK, message, data, meta))
}

// writeCreated writes a 201 Created response.
func writeCreated(ctx *fasthttp.RequestCtx, message string, data interface{}) {
	writeJSON(ctx, fasthttp.StatusCreated, model.NewSuccessResponse(fasthttp.StatusCreated, message, data))
}

// writeError writes an error response.
func writeError(ctx *fasthttp.RequestCtx, code int, errType, message string) {
	writeJSON(ctx, code, model.NewErrorResponse(code, errType, message, nil))
}

// writeValidationError writes a validation error response.
func writeValidationError(ctx *fasthttp.RequestCtx, message string, details []model.ErrorDetail) {
	writeJSON(ctx, fasthttp.StatusBadRequest, model.NewValidationError(message, details))
}

// handleServiceError maps service errors to structured HTTP responses without leaking internal stack details.
func handleServiceError(ctx *fasthttp.RequestCtx, err error) {
	switch {
	case errors.Is(err, model.ErrAccountNotFound):
		writeError(ctx, fasthttp.StatusNotFound, model.ErrNotFound, "Account not found")
	case errors.Is(err, model.ErrAccountExists):
		writeError(ctx, fasthttp.StatusConflict, model.ErrConflict, err.Error())
	case errors.Is(err, model.ErrSecretInUse):
		writeError(ctx, fasthttp.StatusConflict, model.ErrConflict, "Secret already in use")
	case errors.Is(err, model.ErrInvalidProtocol):
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol (must be ssh, vless, vmess, trojan, or noobz)")
	case errors.Is(err, model.ErrInvalidService):
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid or disallowed service/action")
	case errors.Is(err, model.ErrXrayTestFailed):
		writeError(ctx, fasthttp.StatusInternalServerError, model.ErrInternal, "Xray config validation failed")
	default:
		writeError(ctx, fasthttp.StatusInternalServerError, model.ErrInternal, "Internal server error")
	}
}

// getUserValue safely extracts a route parameter string from ctx.UserValue.
func getUserValue(ctx *fasthttp.RequestCtx, key string) string {
	v, ok := ctx.UserValue(key).(string)
	if !ok {
		return ""
	}
	return v
}

// sanitizeFilename sanitizes a string for safe Content-Disposition headers.
func sanitizeFilename(s string) string {
	replacer := strings.NewReplacer(
		"/", "_",
		"\\", "_",
		"..", "_",
		"\"", "",
		"\r", "",
		"\n", "",
		"\t", "",
	)
	return replacer.Replace(s)
}

// generateRandomString generates a CSPRNG hex string of the given length.
func generateRandomString(length int) string {
	bytes := make([]byte, (length+1)/2)
	if _, err := rand.Read(bytes); err != nil {
		return fmt.Sprintf("rnd%d", length)
	}
	return hex.EncodeToString(bytes)[:length]
}

// TrimPrefix trims a prefix from a string.
func TrimPrefix(s, prefix string) string {
	return strings.TrimPrefix(s, prefix)
}
