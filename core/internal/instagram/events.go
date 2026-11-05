package instagram

import (
	"context"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"strconv"
)

func (b *Backend) event(ctx context.Context, event slidetypes.ClientEvent) error {
	switch e := event.(type) {
	case *slidetypes.Connected:
		b.connected.Store(true)
		b.status("connected", "Connected")
		return b.sink.Emit("sync_required", map[string]bool{"ok": true})
	case *slidetypes.Disconnected:
		b.connected.Store(false)
		b.status("reconnecting", "Connection lost. Reconnecting…")
	case *slidetypes.AuthError:
		b.connected.Store(false)
		b.status("login_required", "Instagram needs you to sign in again or complete a security check.")
	case *slidetypes.ResnapshotRequired:
		b.connected.Store(false)
		b.status("reconnecting", "Restoring message synchronization…")
		return b.sink.Emit("reconnect_required", map[string]bool{"ok": true})
	case *slidetypes.ReconnectionStateUpdate:
		// Cache is optional. A fresh LoadIndex is used at startup; authentication is stored separately.
		b.mu.Lock()
		b.state.Cache = e.State
		b.mu.Unlock()
	case *slidetypes.SeqIDUpdate:
		b.mu.Lock()
		b.state.SeqID = e.SeqID
		b.state.SeqTime = e.Timestamp
		b.mu.Unlock()
		return b.persist(ctx)
	case *slidetypes.Delta:
		switch d := e.Data.(type) {
		case *slidetypes.NewMessageEvent:
			if d.Message != nil {
				return b.sink.Emit("message", convertMessage(d.Message, e.ThreadIGID, b.ownID()))
			}
		case *slidetypes.AdminMessageEvent:
			if d.Message != nil {
				return b.sink.Emit("message", convertMessage(d.Message, e.ThreadIGID, b.ownID()))
			}
		case *slidetypes.EditMessageEvent:
			return b.sink.Emit("message_edit", map[string]string{"id": d.MessageID, "threadID": e.ThreadIGID, "text": d.TextBody})
		case *slidetypes.DeleteMessageEvent:
			return b.sink.Emit("message_delete", map[string]string{"id": d.MessageID, "threadID": e.ThreadIGID})
		case *slidetypes.DeleteThreadEvent:
			return b.sink.Emit("conversation_delete", map[string]string{"id": e.ThreadIGID})
		case *slidetypes.ReadReceiptEvent:
			if strconv.FormatInt(d.ReadReceipt.ParticipantFBID, 10) == b.ownID() {
				return b.sink.Emit("read_receipt", map[string]any{"threadID": e.ThreadIGID, "timestamp": d.ReadReceipt.WatermarkTimestampMS.UnixMilli()})
			}
		case *slidetypes.MarkReadEvent:
			return b.sink.Emit("read_receipt", map[string]any{"threadID": e.ThreadIGID, "timestamp": d.ReadTimestampMS.UnixMilli()})
		default:
			return b.sink.Emit("sync_required", map[string]bool{"ok": true})
		}
	}
	return nil
}
