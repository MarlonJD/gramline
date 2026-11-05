package instagram

import (
	"context"
	"errors"
	"testing"
	"time"

	"go.mau.fi/mautrix-meta/pkg/messagix/bloks"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

func TestApprovalRunsNamedOneShotAndRepeatingTimers(t *testing.T) {
	browser, err := bloks.NewBrowser(&bloks.BrowserConfig{Platform: types.Instagram})
	if err != nil {
		t.Fatal(err)
	}
	browser.State = bloks.StateAFADPageWaiting
	delivery, approvals := 0, 0
	err = browser.Bridge.StartTimer("new-delivery-stage", 0, false, func() error {
		delivery++
		return browser.Bridge.StartTimer("new-approval-stage", time.Millisecond, true, func() error {
			approvals++
			if approvals == 2 {
				if err := browser.Bridge.CancelTimer("new-approval-stage"); err != nil {
					return err
				}
				browser.State = bloks.StateSuccess
			}
			return nil
		})
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	step, err := browser.DoLoginStep(ctx, nil)
	if err != nil || step != nil || browser.State != bloks.StateSuccess {
		t.Fatalf("approval did not finish: %v", err)
	}
	if delivery != 1 || approvals != 2 {
		t.Fatalf("incorrect timer counts: %d, %d", delivery, approvals)
	}
}

func TestApprovalTimerReplacementAndCancellation(t *testing.T) {
	browser, err := bloks.NewBrowser(&bloks.BrowserConfig{Platform: types.Instagram})
	if err != nil {
		t.Fatal(err)
	}
	browser.State = bloks.StateAFADPageWaiting
	if err = browser.Bridge.CancelTimer("already-stopped"); err != nil {
		t.Fatal(err)
	}
	oldCalled := false
	_ = browser.Bridge.StartTimer("same-name", 0, true, func() error { oldCalled = true; return nil })
	_ = browser.Bridge.StartTimer("same-name", time.Hour, true, func() error { return nil })
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = browser.DoLoginStep(ctx, nil)
	if !errors.Is(err, context.Canceled) || oldCalled {
		t.Fatalf("cancelled approval still ran: %v", err)
	}
}

func TestTimerInterpreterPreservesRepeatFlagAndCallbackArguments(t *testing.T) {
	for _, repeatFlag := range []string{"false", "0", "true", "1"} {
		t.Run(repeatFlag, func(t *testing.T) {
			var repeated bool
			var callback func() error
			interp := &bloks.Interpreter{LocalVars: map[bloks.BloksVariableID]*bloks.BloksScriptLiteral{}, GlobalVars: map[bloks.BloksVariableID]*bloks.BloksScriptLiteral{}, Bridge: bloks.InterpBridge{
				StartTimer: func(_ string, _ time.Duration, repeat bool, cb func() error) error {
					repeated = repeat
					callback = cb
					return nil
				},
				HandleVariableChange: func(context.Context, string, *bloks.BloksScriptLiteral) error { return nil },
			}}
			var script bloks.BloksScriptNode
			_, err := script.ParseAny(`(bk.action.timer.Start "owner" 10 `+repeatFlag+` (bk.action.core.FuncConst (bk.action.bloks.WriteGlobalConsistencyStore "arguments" (bk.action.array.Make (bk.action.core.GetArg 0) (bk.action.core.GetArg 1)))) "test-timer")`, 0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = interp.Evaluate(context.Background(), &script); err != nil {
				t.Fatal(err)
			}
			if repeated != (repeatFlag == "true" || repeatFlag == "1") {
				t.Fatal("repeat flag ignored")
			}
			if err = callback(); err != nil {
				t.Fatal(err)
			}
			args := interp.GlobalVars["arguments"].Flatten(false).([]any)
			if len(args) != 2 || args[0] != "test-timer" || args[1] != "owner" {
				t.Fatalf("wrong callback arguments: %v", args)
			}
		})
	}
}

func TestApprovalPageRendersThenCompletesThroughItsTimer(t *testing.T) {
	browser, err := bloks.NewBrowser(&bloks.BrowserConfig{Platform: types.Instagram})
	if err != nil {
		t.Fatal(err)
	}
	browser.State = bloks.StateAFADPage
	browser.Bridge.HandleVariableChange = func(_ context.Context, name string, _ *bloks.BloksScriptLiteral) error {
		if name == "approved" {
			browser.State = bloks.StateSuccess
		}
		return nil
	}
	var onAppear bloks.BloksTreeScript
	err = onAppear.Parse(`(bk.action.core.TakeLast (bk.action.array.Concat (bk.action.array.Slice (bk.action.array.Make "old" "pending") 1 null) (bk.action.array.Make "next")) (bk.action.timer.Start (bk.action.core.GetArg 0) 0 false (bk.action.core.FuncConst (bk.action.bloks.WriteGlobalConsistencyStore "approved" true)) "current-approval-check"))`)
	if err != nil {
		t.Fatal(err)
	}
	components := bloks.BloksTreeComponentList{
		&bloks.BloksTreeComponent{ComponentID: "bk.data.TextSpan", Attributes: map[bloks.BloksAttributeID]*bloks.BloksTreeNode{
			"text": {BloksTreeNodeContent: &bloks.BloksTreeLiteral{BloksJavaScriptValue: "We sent a notification to your device"}},
		}},
		&bloks.BloksTreeComponent{ComponentID: "bk.components.VisibilityExtension", Attributes: map[bloks.BloksAttributeID]*bloks.BloksTreeNode{
			"on_appear": {BloksTreeNodeContent: &onAppear},
		}},
	}
	page := &bloks.BloksBundle{Layout: bloks.BloksLayout{Payload: bloks.BloksPayload{Tree: &bloks.BloksTreeNode{BloksTreeNodeContent: &components}}}}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err = page.SetupInterpreter(ctx, browser.Bridge, nil, true); err != nil {
		t.Fatal(err)
	}
	browser.CurrentPage = page
	step, err := browser.DoLoginStep(ctx, nil)
	if err != nil || step == nil || step.Type != "display_and_wait" {
		t.Fatalf("approval page did not render: %v", err)
	}
	step, err = browser.DoLoginStep(ctx, nil)
	if err != nil || step != nil || browser.State != bloks.StateSuccess {
		t.Fatalf("approval did not complete: %v", err)
	}
}
