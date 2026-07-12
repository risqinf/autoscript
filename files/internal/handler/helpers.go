package handler

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/valyala/fasthttp"
	"github.com/risqinf/autoscript-api/internal/model"
)

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

// handleServiceError maps service errors to HTTP responses.
func handleServiceError(ctx *fasthttp.RequestCtx, err error) {
	switch {
	case errors.Is(err, model.ErrAccountNotFound):
		writeError(ctx, fasthttp.StatusNotFound, model.ErrNotFound, "Account not found")
	case errors.Is(err, model.ErrAccountExists):
		writeError(ctx, fasthttp.StatusConflict, model.ErrConflict, "Account already exists")
	case errors.Is(err, model.ErrSecretInUse):
		writeError(ctx, fasthttp.StatusConflict, model.ErrConflict, "Secret already in use")
	case errors.Is(err, model.ErrInvalidProtocol):
		writeError(ctx, fasthttp.StatusBadRequest, model.ErrValidation, "Invalid protocol")
	case errors.Is(err, model.ErrXrayTestFailed):
		writeError(ctx, fasthttp.StatusInternalServerError, model.ErrInternal, "Xray config validation failed")
	default:
		// Log unexpected errors
		writeError(ctx, fasthttp.StatusInternalServerError, model.ErrInternal, "Internal server error")
	}
}

// parseDurationToDays converts a duration string to days.
func parseDurationToDays(duration string) int {
	if len(duration) < 2 {
		return 0
	}

	unit := duration[len(duration)-1]
	value := duration[:len(duration)-1]

	// Parse numeric value
	var num int
	for _, c := range value {
		if c < '0' || c > '9' {
			return 0
		}
		num = num*10 + int(c-'0')
	}

	if num <= 0 {
		return 0
	}

	// Convert to days based on unit
	switch unit {
	case 'm':
		// Minutes: minimum 1 day
		if num < 1440 { // less than 24 hours
			return 1
		}
		return num / 1440
	case 'h':
		// Hours: minimum 1 day
		if num < 24 {
			return 1
		}
		return num / 24
	case 'd':
		// Days
		return num
	default:
		return 0
	}
}

// sanitizeFilename sanitizes a string for use in filenames.
func sanitizeFilename(s string) string {
	// Remove path separators and other dangerous characters
	replacer := strings.NewReplacer(
		"/", "_",
		"\\", "_",
		"..", "_",
		"\r", "",
		"\n", "",
		"\t", "",
	)
	return replacer.Replace(s)
}

// generateRandomString generates a random hex string of the given length.
func generateRandomString(length int) string {
	bytes := make([]byte, (length+1)/2)
	if _, err := rand.Read(bytes); err != nil {
		// Fallback to a simple string if CSPRNG fails
		return fmt.Sprintf("fallback%d", length)
	}
	return hex.EncodeToString(bytes)[:length]
}

// TrimPrefix is a helper to trim a prefix from a string.
func TrimPrefix(s, prefix string) string {
	return strings.TrimPrefix(s, prefix)
}
