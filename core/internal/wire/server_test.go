package wire

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"testing"
	"time"
)

type handlerFunc func(context.Context, string, json.RawMessage) (any, error)

func (f handlerFunc) Handle(ctx context.Context, kind string, data json.RawMessage) (any, error) {
	return f(ctx, kind, data)
}

func TestPersistenceRequiresParentAcknowledgement(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	in, writer := io.Pipe()
	out, reader := io.Pipe()
	defer writer.Close()
	defer out.Close()
	server := New(reader)
	done := make(chan error, 1)
	go func() {
		done <- server.Run(ctx, in, handlerFunc(func(ctx context.Context, _ string, _ json.RawMessage) (any, error) {
			return nil, server.Persist(ctx, map[string]int{"version": 1})
		}))
	}()
	enc, dec := json.NewEncoder(writer), json.NewDecoder(out)
	_ = enc.Encode(map[string]any{"v": 1, "id": "login", "type": "login"})
	var event Frame
	if err := dec.Decode(&event); err != nil {
		t.Fatal(err)
	}
	if event.Type != "session" {
		t.Fatalf("expected session, got %s", event.Type)
	}
	var body struct {
		SaveID string `json:"saveID"`
	}
	_ = json.Unmarshal(event.Data, &body)
	_ = enc.Encode(map[string]any{"v": 1, "type": "session_ack", "data": map[string]any{"saveID": body.SaveID, "ok": false}})
	var response Frame
	if err := dec.Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != "storage" {
		t.Fatal("failed Keychain write did not fail login")
	}
	writer.Close()
	<-done
}

func TestUnstructuredUpstreamErrorsAreNotExposed(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	in, writer := io.Pipe()
	out, reader := io.Pipe()
	defer writer.Close()
	defer out.Close()
	server := New(reader)
	go server.Run(ctx, in, handlerFunc(func(context.Context, string, json.RawMessage) (any, error) {
		return nil, errors.New("password=secret sessionid=secret")
	}))
	_ = json.NewEncoder(writer).Encode(map[string]any{"v": 1, "id": "1", "type": "login"})
	var response Frame
	if err := json.NewDecoder(out).Decode(&response); err != nil {
		t.Fatal(err)
	}
	if response.Error == nil || response.Error.Code != "request_failed" {
		t.Fatal("unexpected error")
	}
	if response.Error.Message != "Instagram could not complete the request. Check your connection and try again." {
		t.Fatal("upstream details escaped")
	}
}

func TestParentEOFCancelsInFlightWork(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	in, writer := io.Pipe()
	started := make(chan struct{})
	stopped := make(chan struct{})
	server := New(io.Discard)
	go server.Run(ctx, in, handlerFunc(func(ctx context.Context, _ string, _ json.RawMessage) (any, error) {
		close(started)
		<-ctx.Done()
		close(stopped)
		return nil, ctx.Err()
	}))
	_ = json.NewEncoder(writer).Encode(map[string]any{"v": 1, "id": "1", "type": "login"})
	<-started
	writer.Close()
	select {
	case <-stopped:
	case <-ctx.Done():
		t.Fatal("helper work survived parent EOF")
	}
}
