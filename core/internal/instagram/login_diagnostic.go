package instagram

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"regexp"
	"strings"

	"go.mau.fi/mautrix-meta/pkg/messagix/bloks"
	"go.mau.fi/mautrix-meta/pkg/messagix/loginerrors"
	"insta-dm/core/internal/wire"
	"maunium.net/go/mautrix/bridgev2"
)

// Diagnostics are constructed from an allowlist. Raw upstream errors can include
// passwords, identifiers, authorization headers or entire response bodies.
type LoginDiagnostic struct {
	Stage      string   `json:"stage"`
	Reason     string   `json:"reason"`
	ErrorType  string   `json:"errorType"`
	HTTPStatus string   `json:"httpStatus,omitempty"`
	Operation  string   `json:"operation,omitempty"`
	Functions  []string `json:"functions,omitempty"`
}

var httpStatusPattern = regexp.MustCompile(`unexpected HTTP status ([1-5][0-9]{2})`)
var bloksOperationPattern = regexp.MustCompile(`(?:unimplemented function|unexpected new screen|can't handle new screen) ((?:bk\.action\.|ig\.action\.|com\.bloks\.)[a-zA-Z0-9_.-]{1,180})(?:[\s(:]|$)`)
var bloksFunctionName = regexp.MustCompile(`^(?:bk\.action\.|ig\.action\.)[a-zA-Z0-9_.]{1,180}$`)

func DiagnoseLogin(err error) (LoginDiagnostic, error) {
	d := LoginDiagnostic{Stage: "verification", Reason: "unsupported_response", ErrorType: fmt.Sprintf("%T", err)}
	var localFault *wire.Fault
	if errors.As(err, &localFault) {
		d.Reason = "local_storage"
		return d, localFault
	}
	for current := err; current != nil; current = errors.Unwrap(current) {
		d.ErrorType = fmt.Sprintf("%T", current)
	}
	text := err.Error() // Inspected only in memory; never returned, logged, or saved.
	switch {
	case strings.Contains(text, "failed to prepare Instagram CAA login"):
		d.Stage = "device_setup"
	case strings.Contains(text, "failed to prepare current Instagram CAA login"):
		d.Stage = "login_preflight"
	case strings.Contains(text, "processing Instagram credential response"), strings.Contains(text, "setting up Instagram credential response"):
		d.Stage = "credential_response"
	case strings.Contains(text, "encrypting Instagram CAA password"):
		d.Stage = "password_encryption"
	case strings.Contains(text, "tapping selected two-factor method"), strings.Contains(text, "invalid two-factor method"):
		d.Stage = "mfa_selection"
	case strings.Contains(text, "tapping continue"):
		d.Stage = "verification_continue"
	case strings.Contains(text, "AFAD"), strings.Contains(text, "waiting for approval"):
		d.Stage = "device_approval"
	}
	if match := httpStatusPattern.FindStringSubmatch(text); len(match) == 2 {
		d.HTTPStatus = match[1]
		d.Reason = "http_rejected"
	}
	known := []struct{ match, reason string }{
		{"invalid two-factor method", "invalid_mfa_selection"},
		{"no such button", "button_missing"}, {"couldn't find any event handlers on button", "button_handler_missing"},
		{"couldn't find AFAD notification info", "approval_instructions_missing"}, {"no AFAD timer scheduled", "approval_timer_missing"},
		{"unimplemented function", "unsupported_function"}, {"unexpected new screen", "unsupported_screen"}, {"can't handle new screen", "unsupported_screen"},
		{"failed to advance flow", "flow_did_not_advance"}, {"unexpected state", "unsupported_step"},
		{"unexpected timer", "unsupported_timer"}, {"unhandled action rpc", "unsupported_action"}, {"unhandled page rpc", "unsupported_page"},
		{"asnonnull got null", "required_value_missing"}, {"no such script", "script_missing"},
		{"couldn't find any mfa types at all", "mfa_methods_missing"},
		{"invalid password key ID", "password_key_missing"}, {"did not provide a password public key", "password_key_missing"},
		{"did not expose its CAA account access context", "account_context_missing"}, {"missing CAA preflight state", "preflight_state_missing"},
		{"did not return a login step", "login_step_missing"}, {"exceeded automatic step limit", "step_limit"},
		{"failed to parse Instagram Bloks response", "response_parse"}, {"unknown function", "unsupported_function"},
		{"unrecognized function", "unsupported_function"}, {"unknown opcode", "unsupported_function"},
		{"unknown login state", "unsupported_step"}, {"Invalid username or password", "credentials_rejected"},
	}
	for _, candidate := range known {
		if strings.Contains(text, candidate.match) {
			d.Reason = candidate.reason
			break
		}
	}
	if match := bloksOperationPattern.FindStringSubmatch(text); len(match) == 2 {
		d.Operation = match[1]
	}
	var unsupported *bloks.UnsupportedFunctionError
	if errors.As(err, &unsupported) {
		for _, name := range unsupported.Functions {
			if bloksFunctionName.MatchString(string(name)) {
				d.Functions = append(d.Functions, string(name))
			}
		}
	}
	var dns *net.DNSError
	var netError net.Error
	var cert *tls.CertificateVerificationError
	var syntax *json.SyntaxError
	switch {
	case errors.As(err, &dns):
		d.Reason = "dns"
	case errors.As(err, &cert):
		d.Reason = "tls_certificate"
	case errors.Is(err, context.DeadlineExceeded):
		d.Reason = "timeout"
	case errors.Is(err, context.Canceled):
		d.Reason = "cancelled"
	case errors.As(err, &netError):
		d.Reason = "network"
	case errors.As(err, &syntax):
		d.Reason = "response_parse"
	}
	knownErrors := []struct {
		err           error
		code, message string
	}{
		{loginerrors.RateLimited, "rate_limited", "Instagram is limiting sign-in attempts. Wait before trying again."},
		{loginerrors.NoSupportedMFA, "unsupported_mfa", "Instagram did not offer a verification method supported by this sign-in flow. Keep two-factor authentication enabled; complete the security check in Instagram."},
		{loginerrors.MandatoryPasskey, "passkey_required", "Instagram requires a passkey for this sign-in. Complete the check in Instagram."},
		{loginerrors.ReCaptcha, "captcha_required", "Instagram requires an interactive CAPTCHA. Complete that check in Instagram before signing in here."},
		{loginerrors.AFADStopped, "approval_expired", "The sign-in approval expired or was declined. Start sign-in again."},
		{loginerrors.NoSMSAvailable, "sms_unavailable", "Instagram could not send a verification SMS. Try another offered verification method or wait before retrying."},
		{loginerrors.TokenExchange, "token_exchange", "Instagram approved sign-in but did not provide a usable session. Complete any pending check in Instagram."},
		{loginerrors.AccountSuspended, "account_suspended", "Instagram reports that the account is suspended. Review the account in Instagram."},
		{loginerrors.PhoneNumber, "username_required", "Use your Instagram username or email address instead of a phone number."},
	}
	for _, candidate := range knownErrors {
		if errors.Is(err, candidate.err) {
			d.Reason = candidate.code
			return d, &wire.Fault{Code: candidate.code, Message: candidate.message}
		}
	}
	var response bridgev2.RespError
	if errors.As(err, &response) {
		switch response.ErrCode {
		case "FI.MAU.META_ACCOUNT_RECOVERY_REQUIRED":
			d.Reason = "account_recovery"
			return d, &wire.Fault{Code: d.Reason, Message: "Instagram requires account recovery, not an OTP code. Complete recovery in Instagram, then start sign-in again."}
		case "FI.MAU.META_UNINFORMATIVE_ERROR":
			d.Reason = "login_rejected"
		}
	}
	message := "Instagram could not finish sign-in."
	switch d.Reason {
	case "dns", "network", "timeout":
		message = "Could not reach Instagram during sign-in. Check your connection and try again."
	case "tls_certificate":
		message = "Instagram’s secure connection could not be verified. Check the network connection."
	case "password_key_missing":
		message = "Instagram did not provide the encryption key needed to start sign-in. This happened before an OTP step."
	case "account_context_missing", "preflight_state_missing":
		message = "Instagram’s sign-in page could not be initialized. This happened before an OTP step."
	case "credentials_rejected":
		message = "Instagram did not accept the username or password."
	case "response_parse", "unsupported_function", "unsupported_step", "unsupported_screen", "login_step_missing", "button_missing", "button_handler_missing", "flow_did_not_advance", "approval_instructions_missing", "approval_timer_missing":
		message = "Instagram returned a sign-in response this client could not process."
	case "cancelled":
		message = "The sign-in attempt was cancelled. Start sign-in again."
	case "http_rejected":
		message = "Instagram rejected a sign-in request (HTTP " + d.HTTPStatus + ")."
	}
	return d, &wire.Fault{Code: "login_" + d.Reason, Message: message + " Diagnostic: " + d.Stage + "/" + d.Reason + "."}
}
