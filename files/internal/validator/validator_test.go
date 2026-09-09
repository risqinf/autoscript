package validator

import (
	"testing"

	"github.com/risqinf/autoscript-api/internal/model"
)

func TestValidatorProtocols(t *testing.T) {
	v := New()

	protocols := []string{"ssh", "vless", "vmess", "trojan", "noobz"}
	for _, p := range protocols {
		if !v.IsValidProtocol(p) {
			t.Errorf("expected protocol %q to be valid", p)
		}
	}

	if v.IsValidProtocol("invalid_proto") {
		t.Errorf("expected invalid_proto to be invalid")
	}
}

func TestValidateNoobzCreateAccount(t *testing.T) {
	v := New()

	validReq := &model.CreateAccountRequest{
		Username: "valid_user",
		Password: "Password123",
		Days:     30,
		LimitIP:  2,
		Quota:    50,
	}

	details := v.ValidateCreateAccount("noobz", validReq)
	if len(details) > 0 {
		t.Fatalf("expected valid noobz request to have 0 errors, got: %v", details)
	}

	invalidReq := &model.CreateAccountRequest{
		Username: "ab", // too short
		Password: "bad password with space",
		Days:     0,  // invalid days
		LimitIP:  -1, // invalid
		Quota:    -1, // invalid
	}

	details = v.ValidateCreateAccount("noobz", invalidReq)
	if len(details) != 5 {
		t.Errorf("expected 5 validation errors for invalidReq, got %d: %v", len(details), details)
	}
}
