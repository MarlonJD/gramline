package instagram

import (
	"context"
	"testing"
	"time"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/util/jsontime"
)

func TestOnlyViewerReadReceiptsUpdateUnreadBadge(t *testing.T) {
	b, _, sink := fixture()
	event := &slidetypes.Delta{ThreadIGID: "thread", Data: &slidetypes.ReadReceiptEvent{ReadReceipt: slidetypes.ReadReceipt{
		ParticipantFBID: 3, WatermarkTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(200)},
	}}}
	if err := b.event(context.Background(), event); err != nil {
		t.Fatal(err)
	}
	if len(sink.events) != 0 {
		t.Fatal("another participant's receipt changed our unread state")
	}
	event.Data.(*slidetypes.ReadReceiptEvent).ReadReceipt.ParticipantFBID = 2
	if err := b.event(context.Background(), event); err != nil {
		t.Fatal(err)
	}
	if sink.count("read_receipt") != 1 || sink.count("sync_required") != 0 {
		t.Fatal("viewer receipt was not emitted directly")
	}
	data := sink.events[0].value.(map[string]any)
	if data["threadID"] != "thread" || data["timestamp"] != int64(200) {
		t.Fatal("receipt lost its thread or timestamp")
	}
	event.Data = &slidetypes.MarkReadEvent{ReadTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(300)}}
	if err := b.event(context.Background(), event); err != nil {
		t.Fatal(err)
	}
	if sink.count("read_receipt") != 2 || sink.events[1].value.(map[string]any)["timestamp"] != int64(300) {
		t.Fatal("mark-read from another device did not advance the viewer receipt")
	}
}
