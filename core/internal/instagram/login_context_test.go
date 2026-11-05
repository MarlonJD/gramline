package instagram

import (
	"context"
	"errors"
	"testing"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/bloks"
)

func TestApprovalTimerSurvivesInputStepAndStopsWithLogin(t *testing.T) {
	parent, stopParent := context.WithCancel(context.Background())
	defer stopParent()
	b := New(parent, &recorder{})
	b.beginLogin(parent)
	defer b.finishLogin()

	var callback func() error
	interp := &bloks.Interpreter{
		LocalVars:  map[bloks.BloksVariableID]*bloks.BloksScriptLiteral{},
		GlobalVars: map[bloks.BloksVariableID]*bloks.BloksScriptLiteral{},
		Bridge: bloks.InterpBridge{
			StartTimer:           func(_ string, _ time.Duration, _ bool, cb func() error) error { callback = cb; return nil },
			HandleVariableChange: func(ctx context.Context, _ string, _ *bloks.BloksScriptLiteral) error { return ctx.Err() },
		},
	}
	var action bloks.BloksScriptNode
	_, err := action.ParseAny(`(bk.action.timer.Start null 1000 true (bk.action.core.FuncConst (bk.action.bloks.WriteGlobalConsistencyStore "approval" "poll")) "approval-timer")`, 0)
	if err != nil {
		t.Fatal(err)
	}
	// This is the same upstream timer that retains the context supplied while
	// rendering a verification step, then executes it during the next request.
	if _, err = interp.Evaluate(b.loginContext, &action); err != nil {
		t.Fatal(err)
	}
	if callback == nil {
		t.Fatal("approval timer was not registered")
	}
	if err = callback(); err != nil {
		t.Fatalf("approval stopped between input steps: %v", err)
	}
	b.finishLogin()
	if err = callback(); !errors.Is(err, context.Canceled) {
		t.Fatalf("approval continued after cancellation: %v", err)
	}
}

func TestLoginStopsWhenParentPipeCloses(t *testing.T) {
	parent, cancel := context.WithCancel(context.Background())
	b := New(parent, &recorder{})
	b.beginLogin(parent)
	defer b.finishLogin()
	cancel()
	if !errors.Is(b.loginContext.Err(), context.Canceled) {
		t.Fatal("login outlived its parent")
	}
}
