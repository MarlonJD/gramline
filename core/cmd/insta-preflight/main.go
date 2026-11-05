// insta-preflight checks the upstream sign-in setup without account credentials.
// It does not load, create or save an account session and is not included in the app.
package main

import (
	"context"
	"encoding/json"
	"os"
	"time"

	"github.com/rs/zerolog"
	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
	"insta-dm/core/internal/instagram"
)

func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	jar := &cookies.Cookies{Platform: types.Instagram}
	jar.UpdateValues(nil)
	client := instameow.NewClient(instameow.ClientParams{Cookies: jar, Log: zerolog.Nop(), DisableTyping: true})
	step, err := client.DoInstagramCAALoginSteps(ctx, map[string]string{})
	if err != nil {
		diagnostic, safeError := instagram.DiagnoseLogin(err)
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "diagnostic": diagnostic, "message": safeError.Error()})
		os.Exit(1)
	}
	if step == nil {
		_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "stage": "preflight", "reason": "missing_credentials_step"})
		os.Exit(1)
	}
	_ = json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "stepType": step.Type, "stepID": step.StepID})
}
