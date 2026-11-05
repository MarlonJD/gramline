package instagram

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/responses"
	"insta-dm/core/internal/wire"
)

type messagingAPI interface {
	IsAuthenticated() bool
	GetMailbox(context.Context) (*slidetypes.MailboxResponse, error)
	PaginateMailbox(context.Context, *slidetypes.PaginateMailboxRequest) (*slidetypes.PaginateMailboxResponse, error)
	GetThread(context.Context, *slidetypes.GetThreadInfoRequest) (*slidetypes.ThreadInfoResponse, error)
	PaginateMessages(context.Context, *slidetypes.PaginateMessagesRequest) (*slidetypes.PaginateMessagesResponse, error)
	SendMessage(context.Context, *slidetypes.SendTextRequest) (*slidetypes.SendTextResponse, error)
	SendMedia(context.Context, *slidetypes.SendMediaRequest) (*slidetypes.SendMediaResponse, error)
	UploadMedia(context.Context, int64, *httpclient.MercuryUploadMedia) (int64, error)
	FetchMedia(context.Context, string, string) (*responses.FetchMediaResponse, error)
}

func (b *Backend) syncInbox(ctx context.Context, anchors map[string]int64) (any, error) {
	mailbox, err := b.api.GetMailbox(ctx)
	if err != nil {
		return nil, classified(err, "Could not refresh conversations.")
	}
	if mailbox.GetMailbox() == nil {
		return nil, &wire.Fault{Code: "empty_response", Message: "Instagram did not return a mailbox."}
	}
	own := b.ownID()
	seen := make(map[string]bool)
	process := func(threads []slidetypes.Node[slidetypes.WrappedThreadInfo]) error {
		for _, edge := range threads {
			t := edge.Node.AsIGDirectThread
			if t == nil || t.ID == "" || seen[t.ID] {
				continue
			}
			seen[t.ID] = true
			conversation := convertThread(t, own)
			if err := b.sink.Emit("conversation", conversation); err != nil {
				return err
			}
			anchor := anchors[t.ID]
			if anchor > 0 && conversation.UpdatedAt <= anchor {
				continue
			}
			// The first mailbox snapshot establishes the catch-up baseline. Load
			// full history when a conversation opens, not once per old conversation.
			page := convertPage(t.SlideMessages, t.ID, own)
			if anchor > 0 {
				page, err = b.history(ctx, t.ID, "")
				if err != nil {
					return err
				}
			}
			watermark := conversation.UpdatedAt
			cursors := map[string]bool{}
			for {
				if err = b.sink.Emit("messages", page); err != nil {
					return err
				}
				found := anchor == 0
				for _, m := range page.Messages {
					if m.Timestamp <= anchor {
						found = true
					}
					if m.Timestamp > watermark {
						watermark = m.Timestamp
					}
				}
				if found || !page.HasMore {
					break
				}
				if page.Cursor == "" || cursors[page.Cursor] {
					return &wire.Fault{Code: "pagination", Message: "Instagram returned a repeated history cursor. Synchronization is incomplete; try refreshing again."}
				}
				cursors[page.Cursor] = true
				page, err = b.history(ctx, t.ID, page.Cursor)
				if err != nil {
					return err
				}
			}
			if err = b.sink.Emit("thread_synced", map[string]any{"threadID": t.ID, "timestamp": watermark}); err != nil {
				return err
			}
		}
		return nil
	}
	pinned := make([]slidetypes.Node[slidetypes.WrappedThreadInfo], 0, len(mailbox.Mailbox.PinnedThreadsV2))
	for _, p := range mailbox.Mailbox.PinnedThreadsV2 {
		pinned = append(pinned, slidetypes.Node[slidetypes.WrappedThreadInfo]{Node: p})
	}
	if err = process(pinned); err != nil {
		return nil, err
	}
	page := mailbox.Mailbox.ThreadsByFolder
	cursors := map[string]bool{}
	for {
		if err = process(page.Edges); err != nil {
			return nil, err
		}
		if !page.PageInfo.HasNextPage {
			break
		}
		cursor := page.PageInfo.EndCursor
		if cursor == "" || cursors[cursor] {
			return nil, &wire.Fault{Code: "pagination", Message: "Conversation synchronization is incomplete. Refresh to try again."}
		}
		cursors[cursor] = true
		id, _ := strconv.ParseInt(own, 10, 64)
		request := slidetypes.MakePaginateMailboxRequest(id, cursor, "INBOX", nil)
		request.Count = 20
		more, fetchErr := b.api.PaginateMailbox(ctx, request)
		if fetchErr != nil {
			return nil, classified(fetchErr, "Could not load more conversations.")
		}
		if more == nil || more.Mailbox == nil {
			return nil, &wire.Fault{Code: "empty_response", Message: "Instagram did not return the next conversation page."}
		}
		page = more.Mailbox.ThreadsByFolder
	}
	return map[string]int{"conversations": len(seen)}, nil
}

func (b *Backend) startSync(parent context.Context, anchors map[string]int64) (any, error) {
	if b.syncDone != nil {
		select {
		case <-b.syncDone:
		default:
			return map[string]bool{"started": false}, nil
		}
	}
	b.cancelSync()
	ctx, cancel := context.WithTimeout(parent, 10*time.Minute)
	done := make(chan struct{})
	b.stopSync, b.syncDone = cancel, done
	// Capture the authenticated client and account for this job. Connection
	// replacement waits for cancellation, so a job cannot cross account sessions.
	b.mu.Lock()
	worker := &Backend{sink: b.sink, api: b.api, state: Session{Account: b.state.Account}}
	b.mu.Unlock()
	go func() {
		defer close(done)
		defer cancel()
		result, err := worker.syncInbox(ctx, anchors)
		if errors.Is(ctx.Err(), context.Canceled) {
			return
		}
		if err == nil && ctx.Err() == nil {
			err = b.persist(ctx)
		}
		if errors.Is(ctx.Err(), context.Canceled) {
			return
		}
		if ctx.Err() != nil {
			err = ctx.Err()
		}
		if err != nil {
			_ = b.sink.Emit("sync_finished", map[string]any{"error": classified(err, "Could not finish updating conversations. Refresh to continue.")})
		} else {
			_ = b.sink.Emit("sync_finished", map[string]any{"result": result})
		}
	}()
	return map[string]bool{"started": true}, nil
}

func (b *Backend) cancelSync() {
	if b.stopSync != nil {
		b.stopSync()
		<-b.syncDone
		b.stopSync, b.syncDone = nil, nil
	}
}

func (b *Backend) history(ctx context.Context, thread, cursor string) (Page, error) {
	if cursor == "" {
		request := slidetypes.MakeGetThreadInfoRequest(thread)
		request.EnableOffMsysChatThemesQE = true
		resp, err := b.api.GetThread(ctx, request)
		if err != nil {
			return Page{}, classified(err, "Could not load conversation history.")
		}
		if resp == nil || resp.ThreadInfo.AsIGDirectThread == nil {
			return Page{}, &wire.Fault{Code: "empty_response", Message: "This conversation is unavailable."}
		}
		t := resp.ThreadInfo.AsIGDirectThread
		page := convertPage(t.SlideMessages, thread, b.ownID())
		conversation := convertThread(t, b.ownID())
		conversation.ThemeLoaded = true // An explicit null theme restores the default appearance.
		page.Conversation = &conversation
		return page, nil
	}
	resp, err := b.api.PaginateMessages(ctx, &slidetypes.PaginateMessagesRequest{AfterCursor: &cursor, ThreadID: thread, FirstN: 20, InitialMessagePageCount: 20})
	if err != nil {
		return Page{}, classified(err, "Could not load older messages.")
	}
	if resp == nil || resp.ThreadInfo.AsIGDirectThread == nil {
		return Page{}, &wire.Fault{Code: "empty_response", Message: "Instagram did not return message history."}
	}
	return convertPage(resp.ThreadInfo.AsIGDirectThread.Messages, thread, b.ownID()), nil
}

func (b *Backend) send(ctx context.Context, data json.RawMessage) (any, error) {
	if err := b.requireClient(); err != nil {
		return nil, err
	}
	var input struct {
		ThreadID string `json:"threadID"`
		ClientID string `json:"clientID"`
		Text     string `json:"text"`
	}
	if json.Unmarshal(data, &input) != nil || input.ThreadID == "" || strings.TrimSpace(input.Text) == "" || len([]rune(input.Text)) > 1000 {
		return nil, invalid()
	}
	if id, err := strconv.ParseInt(input.ClientID, 10, 64); err != nil || id <= 0 {
		return nil, invalid()
	}
	if !b.connected.Load() {
		return nil, &wire.Fault{Code: "not_sent", Message: "The message was not sent because Instagram is disconnected."}
	}
	attribution := "igd_web_chat_tab:in_thread"
	response, err := b.api.SendMessage(ctx, &slidetypes.SendTextRequest{
		IGThreadIGID: &input.ThreadID, OfflineThreadingID: input.ClientID, Text: slidetypes.SensitiveString{Value: input.Text},
		Mentions: []slidetypes.InputMention{}, MentionedUserIDs: []string{}, Commands: []slidetypes.InputCommand{}, SendAttribution: &attribution,
	})
	// Once the request enters the network, an error is not proof that it failed to send.
	if err != nil || response == nil || response.Message.ID == "" {
		return nil, &wire.Fault{Code: "send_unknown", Message: "Delivery could not be confirmed. Refresh this conversation before sending the message again."}
	}
	m := Message{ID: response.Message.ID, ThreadID: input.ThreadID, ClientID: input.ClientID, SenderID: b.ownID(), Text: input.Text, Timestamp: response.Message.TimestampMS.UnixMilli(), IsOwn: true, Status: "sent", Kind: "text"}
	if m.Timestamp <= 0 {
		m.Timestamp = time.Now().UnixMilli()
	}
	return m, nil
}
