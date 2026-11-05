package instagram

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"

	"go.mau.fi/mautrix-meta/pkg/messagix/bloks"
)

func TestBloksArraySliceMatchesInstagramOffsetAndLength(t *testing.T) {
	for _, tc := range []struct {
		name, expression string
		want             any
	}{
		{"offset and length", `(bk.action.array.Slice (bk.action.array.Make "a" "b" "c" "d") 1 2)`, []any{"b", "c"}},
		{"numeric conversion", `(bk.action.array.Slice (bk.action.array.Make "a" "b" "c" "d") 1.9 2.2)`, []any{"b", "c"}},
		{"null length", `(bk.action.array.Slice (bk.action.array.Make "a" "b" "c") 1 null)`, []any{"b", "c"}},
		{"clamped length", `(bk.action.array.Slice (bk.action.array.Make "a" "b" "c") 1 100)`, []any{"b", "c"}},
		{"zero length", `(bk.action.array.Slice (bk.action.array.Make "a") 0 0)`, []any{}},
		{"negative offset", `(bk.action.array.Slice (bk.action.array.Make "a") -1 1)`, nil},
		{"offset at end", `(bk.action.array.Slice (bk.action.array.Make "a") 1 null)`, nil},
		{"negative length", `(bk.action.array.Slice (bk.action.array.Make "a") 0 -1)`, nil},
		{"empty array", `(bk.action.array.Slice (bk.action.array.Make) 0 null)`, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var action bloks.BloksScriptNode
			if _, err := action.ParseAny(tc.expression, 0); err != nil {
				t.Fatal(err)
			}
			got, err := (&bloks.Interpreter{}).Evaluate(context.Background(), &action)
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(got.Flatten(false), tc.want) {
				t.Fatalf("got %#v, want %#v", got.Flatten(false), tc.want)
			}
		})
	}
}

func TestBloksConcatAfterSliceKeepsBothArrays(t *testing.T) {
	var action bloks.BloksScriptNode
	_, err := action.ParseAny(`(bk.action.array.Concat (bk.action.array.Slice (bk.action.array.Make "expired" "pending") 1 null) (bk.action.array.Make "next"))`, 0)
	if err != nil {
		t.Fatal(err)
	}
	value, err := (&bloks.Interpreter{}).Evaluate(context.Background(), &action)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(value.Flatten(false), []any{"pending", "next"}) {
		t.Fatalf("unexpected concatenation: %#v", value.Flatten(false))
	}

	left := make([]*bloks.BloksScriptLiteral, 1, 4)
	left[0] = bloks.BloksLiteralOf("original")
	call := &bloks.BloksScriptNode{Content: &bloks.BloksScriptFuncall{
		Function: "bk.action.array.Concat",
		Args:     []bloks.BloksScriptNode{{Content: bloks.BloksLiteralOf(left)}, {Content: bloks.BloksLiteralOf([]*bloks.BloksScriptLiteral{})}},
	}}
	result, err := (&bloks.Interpreter{}).Evaluate(context.Background(), call)
	if err != nil {
		t.Fatal(err)
	}
	result.Value().([]*bloks.BloksScriptLiteral)[0] = bloks.BloksLiteralOf("changed")
	if left[0].Value() != "original" {
		t.Fatal("concatenation aliased its input")
	}
}

func TestBloksDiagnosticInventoryNeverCollectsLiteralValues(t *testing.T) {
	var script bloks.BloksTreeScript
	if err := script.Parse(`(bk.action.core.TakeLast "password-never-log-this" "bk.action.secret.private" (bk.action.test.Missing))`); err != nil {
		t.Fatal(err)
	}
	bundle := &bloks.BloksBundle{Layout: bloks.BloksLayout{Payload: bloks.BloksPayload{Scripts: map[bloks.BloksScriptID]bloks.BloksTreeScript{"private-variable": script}}}}
	interp, err := bloks.NewInterpreter(context.Background(), bundle, &bloks.InterpBridge{}, nil, true)
	if err != nil {
		t.Fatal(err)
	}
	_, err = interp.Evaluate(context.Background(), &script.AST)
	if err == nil {
		t.Fatal("expected missing function")
	}
	d, safe := DiagnoseLogin(err)
	encoded, _ := json.Marshal(d)
	if strings.Contains(string(encoded)+safe.Error(), "private") || strings.Contains(string(encoded)+safe.Error(), "never-log-this") {
		t.Fatal("script values leaked")
	}
	if !reflect.DeepEqual(d.Functions, []string{"bk.action.core.TakeLast", "bk.action.test.Missing"}) {
		t.Fatalf("unexpected inventory: %v", d.Functions)
	}
}
