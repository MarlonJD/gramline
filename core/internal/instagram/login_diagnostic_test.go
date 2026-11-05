package instagram

import (
	"encoding/json"
	"errors"
	"fmt"
	"go.mau.fi/mautrix-meta/pkg/messagix/loginerrors"
	"insta-dm/core/internal/wire"
	"strings"
	"testing"
)

func TestLoginDiagnosticsNeverExposeRawErrors(t *testing.T) {
	diagnostic, safe := DiagnoseLogin(fmt.Errorf("failed to prepare Instagram CAA login: instagram app returned an invalid password key ID: password=never-log-this sessionid=private"))
	encoded, _ := json.Marshal(diagnostic)
	if strings.Contains(string(encoded)+safe.Error(), "never-log-this") || strings.Contains(string(encoded)+safe.Error(), "private") {
		t.Fatal("sensitive upstream details escaped")
	}
	if diagnostic.Stage != "device_setup" || diagnostic.Reason != "password_key_missing" {
		t.Fatalf("unexpected diagnostic: %+v", diagnostic)
	}
}
func TestUnsupportedMFAIsDistinguishedFromBadPassword(t *testing.T) {
	diagnostic, err := DiagnoseLogin(fmt.Errorf("login: %w", loginerrors.NoSupportedMFA))
	var fault *wire.Fault
	if !errors.As(err, &fault) || fault.Code != "unsupported_mfa" || diagnostic.Reason != "unsupported_mfa" {
		t.Fatalf("unexpected MFA classification: %v", err)
	}
}

func TestVerificationDiagnosticsIdentifyFailureWithoutResponseData(t *testing.T) {
	for _, tc := range []struct{ raw, stage, reason, operation string }{
		{"tapping selected two-factor method: no such button", "mfa_selection", "button_missing", ""},
		{"tapping continue button: on_click: unimplemented function bk.action.test.Unsupported (3 args)", "verification_continue", "unsupported_function", "bk.action.test.Unsupported"},
		{"tapping selected two-factor method: unexpected new screen com.bloks.www.test.approval", "mfa_selection", "unsupported_screen", "com.bloks.www.test.approval"},
		{"couldn't find AFAD notification info", "device_approval", "approval_instructions_missing", ""},
		{"no AFAD timer scheduled", "device_approval", "approval_timer_missing", ""},
		{"handling choose-mfa-page failed to advance flow", "verification", "flow_did_not_advance", ""},
		{"unimplemented function sessionid=never-log-this", "verification", "unsupported_function", ""},
	} {
		t.Run(tc.reason+tc.stage, func(t *testing.T) {
			d, safe := DiagnoseLogin(errors.New(tc.raw + " password=never-log-this"))
			encoded, _ := json.Marshal(d)
			if strings.Contains(string(encoded)+safe.Error(), "never-log-this") {
				t.Fatal("raw error leaked")
			}
			if d.Stage != tc.stage || d.Reason != tc.reason || d.Operation != tc.operation {
				t.Fatalf("unexpected diagnostic: %+v", d)
			}
		})
	}
}
