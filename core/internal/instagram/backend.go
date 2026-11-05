package instagram

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
	"maunium.net/go/mautrix/bridgev2"

	"insta-dm/core/internal/wire"
)

type Sink interface {
	Emit(string, any) error
	Persist(context.Context, any) error
}

type Backend struct {
	sink         Sink
	root         context.Context
	mu           sync.Mutex
	persistMu    sync.Mutex
	state        Session
	client       *instameow.Client
	api          messagingAPI
	generation   atomic.Uint64
	connected    atomic.Bool
	loginStep    *bridgev2.LoginStep
	loginStarted bool
	loginContext context.Context
	stopLogin    context.CancelFunc
	stopSocket   context.CancelFunc
	stopSync     context.CancelFunc
	syncDone     chan struct{}
	ravenPlan    *ravenPlan
}

func New(ctx context.Context, sink Sink) *Backend {
	return &Backend{root: ctx, sink: sink, state: Session{Version: 1}}
}

func (b *Backend) Close() {
	b.ravenPlan = nil
	b.cancelSync()
	b.finishLogin()
	b.generation.Add(1)
	b.connected.Store(false)
	if b.stopSocket != nil {
		b.stopSocket()
		b.stopSocket = nil
	}
	if b.client != nil {
		b.client.Disconnect()
	}
}

func (b *Backend) makeClient() {
	generation := b.generation.Add(1)
	jar := &cookies.Cookies{Platform: types.Instagram}
	jar.UpdateValues(b.state.Cookies)
	client := instameow.NewClient(instameow.ClientParams{
		Cookies: jar, Log: zerolog.Nop(), NativeSession: b.state.Native,
		MobileLoginDevice: b.state.Device, DisableTyping: true,
		SaveMobileLoginDevice: func(ctx context.Context, d types.InstagramLoginDevice) error {
			b.mu.Lock()
			b.state.Device = &d
			b.mu.Unlock()
			return b.persist(ctx)
		},
		EventHandler: func(ctx context.Context, event slidetypes.ClientEvent) error {
			if b.generation.Load() != generation {
				return nil
			}
			return b.event(ctx, event)
		},
	})
	b.mu.Lock()
	b.client = client
	b.api = &instagramAPI{Client: client}
	b.mu.Unlock()
}

func (b *Backend) persist(ctx context.Context) error {
	b.persistMu.Lock()
	defer b.persistMu.Unlock()
	b.mu.Lock()
	if b.client != nil {
		b.state.Cookies = b.client.GetCookies().GetAll()
		b.state.Native = b.client.GetInstagramNativeSession()
	}
	state := b.state
	b.mu.Unlock()
	return b.sink.Persist(ctx, state)
}

func (b *Backend) status(state, message string) {
	_ = b.sink.Emit("connection", map[string]string{"state": state, "message": message})
}

func (b *Backend) Handle(parent context.Context, kind string, data json.RawMessage) (any, error) {
	ctx, cancel := context.WithTimeout(parent, 60*time.Second)
	defer cancel()
	switch kind {
	case "hello":
		return map[string]any{"name": "insta-core", "protocol": wire.Version, "upstream": "v0.2610.1-0.20261105141638-a3afe226a33a", "patches": []string{"bloks-array-slice", "bloks-array-concat", "bloks-function-diagnostics", "bloks-login-timers"}}, nil
	case "restore":
		var input struct {
			Session *Session `json:"session"`
		}
		if err := json.Unmarshal(data, &input); err != nil {
			return nil, invalid()
		}
		b.Close()
		b.mu.Lock()
		b.state = Session{Version: 1}
		if input.Session != nil {
			b.state = *input.Session
		}
		b.mu.Unlock()
		if b.state.Version != 1 {
			return nil, &wire.Fault{Code: "session_version", Message: "This saved session format is unsupported. Sign out and sign in again."}
		}
		b.makeClient()
		if !b.hasCredentials() {
			b.status("login_required", "Sign in to Instagram")
			return map[string]bool{"authenticated": false}, nil
		}
		return b.connect(ctx)
	case "login":
		var input struct {
			Fields map[string]string `json:"fields"`
		}
		if json.Unmarshal(data, &input) != nil {
			return nil, invalid()
		}
		if b.client == nil {
			b.makeClient()
		}
		if !b.loginStarted && (strings.TrimSpace(input.Fields["username"]) == "" || input.Fields["password"] == "") {
			return nil, invalid()
		}
		if !b.loginStarted {
			b.Close()
			b.mu.Lock()
			device := b.state.Device
			b.state = Session{Version: 1, Device: device}
			b.mu.Unlock()
			b.makeClient()
			b.loginStep = nil
			b.beginLogin(parent)
		}
		if b.loginStep != nil && b.loginStep.UserInputParams != nil {
			for _, field := range b.loginStep.UserInputParams.Fields {
				value := input.Fields[field.ID]
				if value == "" && !field.Optional {
					return nil, &wire.Fault{Code: "login_input", Message: "Complete all required fields."}
				}
				if field.Validate != nil {
					cleaned, err := field.Validate(value)
					if err != nil {
						return nil, &wire.Fault{Code: "login_input", Message: "Check the verification information and try again."}
					}
					input.Fields[field.ID] = cleaned
				}
			}
		}
		b.loginStarted = true
		// Bloks timer callbacks retain this context between user-input steps.
		// Cancelling a request-scoped context here breaks approval on another device.
		step, err := b.client.DoInstagramCAALoginSteps(b.loginContext, input.Fields)
		if err != nil {
			diagnostic, safeError := DiagnoseLogin(err)
			_ = b.sink.Emit("login_diagnostic", diagnostic)
			// A failed credential request must not keep a half-initialized CAA flow.
			if b.loginStep == nil {
				b.loginStarted = false
				b.client.ClearInstagramCAALoginState()
				b.finishLogin()
			}
			return nil, safeError
		}
		b.loginStep = step
		if step != nil {
			return map[string]any{"step": step}, nil
		}
		if err = b.persist(b.loginContext); err != nil {
			return nil, err
		}
		b.loginStarted = false
		result, err := b.connect(b.loginContext)
		b.finishLogin()
		return result, err
	case "cancel_login":
		b.Close()
		b.loginStarted = false
		b.loginStep = nil
		b.mu.Lock()
		device := b.state.Device
		b.state = Session{Version: 1, Device: device}
		b.mu.Unlock()
		b.makeClient()
		b.status("login_required", "Sign in to Instagram")
		return map[string]bool{"ok": true}, b.persist(ctx)
	case "reconnect":
		if !b.hasCredentials() {
			return nil, authRequired()
		}
		b.Close()
		b.makeClient()
		return b.connect(ctx)
	case "sync":
		if err := b.requireClient(); err != nil {
			return nil, err
		}
		var input struct {
			Anchors map[string]int64 `json:"anchors"`
		}
		if json.Unmarshal(data, &input) != nil {
			return nil, invalid()
		}
		return b.startSync(parent, input.Anchors)
	case "history":
		if err := b.requireClient(); err != nil {
			return nil, err
		}
		var input struct {
			ThreadID string `json:"threadID"`
			Cursor   string `json:"cursor"`
		}
		if json.Unmarshal(data, &input) != nil || input.ThreadID == "" {
			return nil, invalid()
		}
		return b.history(ctx, input.ThreadID, input.Cursor)
	case "send":
		return b.send(ctx, data)
	case "shared_post":
		return b.fetchSharedPost(ctx, data)
	case "message_media":
		return b.fetchMessageMedia(ctx, data)
	case "raven_prepare":
		return b.prepareRaven(ctx, data)
	case "raven_open":
		return b.openRaven(ctx, data)
	case "send_media":
		mediaCtx, stop := context.WithTimeout(parent, 3*time.Minute)
		defer stop()
		return b.sendMedia(mediaCtx, data)
	case "logout":
		b.Close()
		b.mu.Lock()
		b.state = Session{Version: 1}
		b.client = nil
		b.mu.Unlock()
		b.loginStep = nil
		b.loginStarted = false
		b.status("login_required", "Sign in to Instagram")
		return map[string]bool{"ok": true}, nil
	default:
		return nil, &wire.Fault{Code: "command", Message: "Unknown command."}
	}
}

func (b *Backend) beginLogin(parent context.Context) {
	b.finishLogin()
	b.loginContext, b.stopLogin = context.WithTimeout(parent, 10*time.Minute)
}

func (b *Backend) finishLogin() {
	if b.stopLogin != nil {
		b.stopLogin()
		b.stopLogin = nil
	}
	b.loginContext = nil
	b.loginStarted = false
	b.loginStep = nil
}

func (b *Backend) connect(ctx context.Context) (any, error) {
	b.status("connecting", "Connecting to Instagram…")
	user, _, err := b.client.LoadIndex(ctx)
	if err != nil {
		b.status("offline", "Could not connect. Your saved messages are available.")
		return nil, classified(err, "Could not connect to Instagram. Check your connection and reconnect.")
	}
	account := &Account{ID: user.ID, MessagingID: strconv.FormatInt(b.client.GetOwnFBID(), 10), Username: user.GetUsername(), Name: user.GetName(), AvatarURL: safeCDNURL(user.GetAvatarURL())}
	if account.ID == "" || account.MessagingID == "0" {
		return nil, &wire.Fault{Code: "account", Message: "Instagram did not return a valid account identity."}
	}
	b.mu.Lock()
	b.state.Account = account
	b.mu.Unlock()
	if err = b.sink.Emit("account", account); err != nil {
		return nil, err
	}
	if err = b.persist(ctx); err != nil {
		return nil, err
	}
	socketCtx, stop := context.WithCancel(b.root)
	b.stopSocket = stop
	go b.client.Connect(socketCtx)
	return map[string]any{"authenticated": true, "account": account}, nil
}

func (b *Backend) requireClient() error {
	if b.api == nil || !b.api.IsAuthenticated() {
		return authRequired()
	}
	return nil
}

func (b *Backend) hasCredentials() bool {
	return b.client != nil && b.client.GetCookies().IsLoggedIn()
}

func (b *Backend) ownID() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.state.Account == nil {
		return ""
	}
	return b.state.Account.MessagingID
}
func invalid() error {
	return &wire.Fault{Code: "invalid_input", Message: "The request is incomplete or invalid."}
}
func authRequired() error {
	return &wire.Fault{Code: "login_required", Message: "Sign in to Instagram to continue."}
}

func classified(err error, message string) error {
	var fault *wire.Fault
	if errors.As(err, &fault) {
		return fault
	}
	if errors.Is(err, httpclient.ErrTokenInvalidated) {
		return authRequired()
	}
	if errors.Is(err, httpclient.ErrRateLimited) {
		return &wire.Fault{Code: "rate_limited", Message: "Instagram is limiting requests. Wait before trying again."}
	}
	if errors.Is(err, httpclient.ErrChallengeRequired) || errors.Is(err, httpclient.ErrCheckpointRequired) || errors.Is(err, httpclient.ErrConsentRequired) {
		return &wire.Fault{Code: "challenge", Message: "Complete the security check in Instagram, then reconnect or sign in again."}
	}
	return &wire.Fault{Code: "request_failed", Message: message}
}
