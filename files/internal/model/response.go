package model

// SuccessResponse represents a successful API response.
type SuccessResponse struct {
	Success bool        `json:"success"`
	Code    int         `json:"code"`
	Message string      `json:"message"`
	Data    interface{} `json:"data,omitempty"`
	Meta    *Meta       `json:"meta,omitempty"`
}

// ErrorResponse represents a failed API response.
type ErrorResponse struct {
	Success bool   `json:"success"`
	Code    int    `json:"code"`
	Error   *Error `json:"error"`
}

// Error contains error details.
type Error struct {
	Type    string        `json:"type"`
	Message string        `json:"message"`
	Details []ErrorDetail `json:"details"`
}

// ErrorDetail contains field-specific error information.
type ErrorDetail struct {
	Field   string `json:"field"`
	Message string `json:"message"`
}

// Meta contains pagination information.
type Meta struct {
	Total   int `json:"total"`
	Page    int `json:"page"`
	PerPage int `json:"per_page"`
}

// NewSuccessResponse creates a new success response.
func NewSuccessResponse(code int, message string, data interface{}) *SuccessResponse {
	return &SuccessResponse{
		Success: true,
		Code:    code,
		Message: message,
		Data:    data,
	}
}

// NewSuccessResponseWithMeta creates a new success response with pagination.
func NewSuccessResponseWithMeta(code int, message string, data interface{}, meta *Meta) *SuccessResponse {
	return &SuccessResponse{
		Success: true,
		Code:    code,
		Message: message,
		Data:    data,
		Meta:    meta,
	}
}

// NewErrorResponse creates a new error response.
func NewErrorResponse(code int, errType, message string, details []ErrorDetail) *ErrorResponse {
	if details == nil {
		details = []ErrorDetail{}
	}
	return &ErrorResponse{
		Success: false,
		Code:    code,
		Error: &Error{
			Type:    errType,
			Message: message,
			Details: details,
		},
	}
}

// NewValidationError creates a validation error response.
func NewValidationError(message string, details []ErrorDetail) *ErrorResponse {
	return NewErrorResponse(400, ErrValidation, message, details)
}

// NewNotFoundError creates a not found error response.
func NewNotFoundError(message string) *ErrorResponse {
	return NewErrorResponse(404, ErrNotFound, message, nil)
}

// NewConflictError creates a conflict error response.
func NewConflictError(message string) *ErrorResponse {
	return NewErrorResponse(409, ErrConflict, message, nil)
}

// NewUnauthorizedError creates an unauthorized error response.
func NewUnauthorizedError(message string) *ErrorResponse {
	return NewErrorResponse(401, ErrUnauthorized, message, nil)
}

// NewForbiddenError creates a forbidden error response.
func NewForbiddenError(message string) *ErrorResponse {
	return NewErrorResponse(403, ErrForbidden, message, nil)
}

// NewRateLimitError creates a rate limit error response.
func NewRateLimitError(message string) *ErrorResponse {
	return NewErrorResponse(429, ErrRateLimited, message, nil)
}

// NewInternalError creates an internal server error response.
func NewInternalError(message string) *ErrorResponse {
	return NewErrorResponse(500, ErrInternal, message, nil)
}
