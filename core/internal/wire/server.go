// Package wire implements the versioned, private JSON-lines pipe protocol.
package wire

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

const Version = 1
const MaxFrame = 16 * 1024 * 1024

type Frame struct {
	V     int             `json:"v"`
	ID    string          `json:"id,omitempty"`
	Type  string          `json:"type"`
	Data  json.RawMessage `json:"data,omitempty"`
	Error *Fault          `json:"error,omitempty"`
}

type Fault struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func (f *Fault) Error() string { return f.Message }

type Handler interface {
	Handle(context.Context, string, json.RawMessage) (any, error)
}

type Server struct {
	out      io.Writer
	writeMu  sync.Mutex
	ackMu    sync.Mutex
	acks     map[string]chan bool
	sequence atomic.Uint64
}

func New(out io.Writer) *Server { return &Server{out: out, acks: make(map[string]chan bool)} }

func (s *Server) write(id, kind string, data any, fault *Fault) error {
	raw, err := json.Marshal(data)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	return json.NewEncoder(s.out).Encode(Frame{V: Version, ID: id, Type: kind, Data: raw, Error: fault})
}

func (s *Server) Emit(kind string, data any) error { return s.write("", kind, data, nil) }

// Persist waits for the parent to commit the state to Keychain before allowing login to continue.
func (s *Server) Persist(ctx context.Context, state any) error {
	id := strconv.FormatUint(s.sequence.Add(1), 10)
	ack := make(chan bool, 1)
	s.ackMu.Lock()
	s.acks[id] = ack
	s.ackMu.Unlock()
	defer func() { s.ackMu.Lock(); delete(s.acks, id); s.ackMu.Unlock() }()
	if err := s.Emit("session", map[string]any{"saveID": id, "state": state}); err != nil {
		return err
	}
	select {
	case ok := <-ack:
		if !ok {
			return &Fault{"storage", "Could not save the session in Keychain. Unlock your login keychain and try again."}
		}
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(30 * time.Second):
		return &Fault{"storage", "Timed out saving the session in Keychain."}
	}
}

func (s *Server) Run(ctx context.Context, in io.Reader, handler Handler) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	commands := make(chan Frame, 32)
	readErr := make(chan error, 1)
	go func() {
		defer cancel() // The helper must not outlive the parent when stdin closes.
		defer close(commands)
		scanner := bufio.NewScanner(in)
		scanner.Buffer(make([]byte, 65536), MaxFrame)
		for scanner.Scan() {
			var frame Frame
			if err := json.Unmarshal(scanner.Bytes(), &frame); err != nil {
				_ = s.write("", "protocol_error", nil, &Fault{"protocol", "Invalid JSON frame."})
				continue
			}
			if frame.V != Version {
				_ = s.write(frame.ID, "response", nil, &Fault{"version", "Unsupported protocol version."})
				continue
			}
			if frame.Type == "session_ack" {
				var a struct {
					SaveID string `json:"saveID"`
					OK     bool   `json:"ok"`
				}
				if json.Unmarshal(frame.Data, &a) == nil {
					s.ackMu.Lock()
					ch := s.acks[a.SaveID]
					s.ackMu.Unlock()
					if ch != nil {
						select {
						case ch <- a.OK:
						default:
						}
					}
				}
				continue
			}
			select {
			case commands <- frame:
			case <-ctx.Done():
				return
			}
		}
		readErr <- scanner.Err()
	}()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case frame, ok := <-commands:
			if !ok {
				return <-readErr
			}
			if frame.ID == "" {
				_ = s.Emit("protocol_error", map[string]string{"message": "A request ID is required."})
				continue
			}
			if frame.Type == "shutdown" {
				return s.write(frame.ID, "response", map[string]bool{"ok": true}, nil)
			}
			result, err := handler.Handle(ctx, frame.Type, frame.Data)
			var fault *Fault
			if err != nil && !errors.As(err, &fault) {
				// Never put upstream errors (which can contain credentials or response bodies) on the wire.
				fault = &Fault{"request_failed", "Instagram could not complete the request. Check your connection and try again."}
			}
			if err := s.write(frame.ID, "response", result, fault); err != nil {
				return fmt.Errorf("write response: %w", err)
			}
		}
	}
}
