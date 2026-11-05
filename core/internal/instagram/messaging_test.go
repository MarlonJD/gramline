package instagram

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"testing"
	"time"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"go.mau.fi/mautrix-meta/pkg/messagix/responses"
	"go.mau.fi/util/jsontime"
	"insta-dm/core/internal/wire"
)

type recordedEvent struct {
	kind  string
	value any
}
type recorder struct{ events []recordedEvent }

func (r *recorder) Emit(kind string, value any) error {
	r.events = append(r.events, recordedEvent{kind, value})
	return nil
}
func (r *recorder) Persist(context.Context, any) error { return nil }
func (r *recorder) count(kind string) int {
	count := 0
	for _, e := range r.events {
		if e.kind == kind {
			count++
		}
	}
	return count
}

type fakeAPI struct {
	fetchedMedia     *responses.FetchMediaResponse
	fetchedMediaID   string
	fetchedShortcode string
	thread           *slidetypes.ThreadInfo
	pages            map[string]*slidetypes.SlideMessages
	pageCalls        int
	threadCalls      int
	failPage         bool
	sendCalls        int
	sendError        error
	mailboxEntered   chan struct{}
	uploadCalls      int
	mediaCalls       int
	uploadError      error
	mediaError       error
	uploaded         *httpclient.MercuryUploadMedia
	mediaRequest     *slidetypes.SendMediaRequest
}

func (f *fakeAPI) IsAuthenticated() bool { return true }

func TestSavedCookiesCanRestoreBeforeViewerIsLoaded(t *testing.T) {
	b, _, _ := fixture()
	if !b.hasCredentials() {
		t.Fatal("saved credentials were treated as logged out before LoadIndex")
	}
	if b.client.IsAuthenticated() {
		t.Fatal("fixture should not have a loaded viewer")
	}
}

func (f *fakeAPI) GetMailbox(ctx context.Context) (*slidetypes.MailboxResponse, error) {
	if f.mailboxEntered != nil {
		close(f.mailboxEntered)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	wrapped := slidetypes.WrappedThreadInfo{AsIGDirectThread: f.thread, ID: f.thread.ID}
	return &slidetypes.MailboxResponse{Mailbox: &slidetypes.Mailbox{
		PinnedThreadsV2: []slidetypes.WrappedThreadInfo{wrapped},
		ThreadsByFolder: slidetypes.Edged[slidetypes.Node[slidetypes.WrappedThreadInfo]]{Edges: []slidetypes.Node[slidetypes.WrappedThreadInfo]{{Node: wrapped}}},
	}}, nil
}
func (f *fakeAPI) PaginateMailbox(context.Context, *slidetypes.PaginateMailboxRequest) (*slidetypes.PaginateMailboxResponse, error) {
	return nil, errors.New("unexpected mailbox pagination")
}
func (f *fakeAPI) GetThread(context.Context, *slidetypes.GetThreadInfoRequest) (*slidetypes.ThreadInfoResponse, error) {
	f.threadCalls++
	return &slidetypes.ThreadInfoResponse{ThreadInfo: slidetypes.WrappedThreadInfo{AsIGDirectThread: f.thread}}, nil
}
func (f *fakeAPI) PaginateMessages(_ context.Context, req *slidetypes.PaginateMessagesRequest) (*slidetypes.PaginateMessagesResponse, error) {
	f.pageCalls++
	if f.failPage {
		return nil, errors.New("network interrupted")
	}
	key := ""
	if req.AfterCursor != nil {
		key = *req.AfterCursor
	}
	if req.OlderThanMessageID != nil {
		key = "before:" + *req.OlderThanMessageID
	}
	return &slidetypes.PaginateMessagesResponse{ThreadInfo: slidetypes.AsThread[slidetypes.MessagesOnlyThread]{AsIGDirectThread: &slidetypes.MessagesOnlyThread{Messages: f.pages[key]}}}, nil
}
func (f *fakeAPI) SendMessage(context.Context, *slidetypes.SendTextRequest) (*slidetypes.SendTextResponse, error) {
	f.sendCalls++
	return nil, f.sendError
}

func (f *fakeAPI) UploadMedia(_ context.Context, _ int64, media *httpclient.MercuryUploadMedia) (int64, error) {
	f.uploadCalls++
	f.uploaded = media
	return 42, f.uploadError
}
func (f *fakeAPI) SendMedia(_ context.Context, request *slidetypes.SendMediaRequest) (*slidetypes.SendMediaResponse, error) {
	f.mediaCalls++
	f.mediaRequest = request
	return &slidetypes.SendMediaResponse{Message: slidetypes.SentMessage{ID: "media-message", TimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(123)}}}, f.mediaError
}

func page(cursor string, more bool, timestamps ...int64) *slidetypes.SlideMessages {
	p := &slidetypes.SlideMessages{PageInfo: slidetypes.PageInfo{EndCursor: cursor, HasNextPage: more}}
	for _, ts := range timestamps {
		p.Edges = append(p.Edges, slidetypes.Node[*slidetypes.Message]{Node: &slidetypes.Message{ID: strconv.FormatInt(ts, 10), TextBody: "hello", TimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(ts)}}})
	}
	return p
}
func fixture() (*Backend, *fakeAPI, *recorder) {
	r := &recorder{}
	b := New(context.Background(), r)
	b.state.Cookies = map[cookies.MetaCookieName]string{cookies.IGCookieSessionID: "test-session"}
	b.state.Account = &Account{ID: "1", MessagingID: "2"}
	b.makeClient()
	f := &fakeAPI{thread: &slidetypes.ThreadInfo{ID: "thread", ThreadTitle: "Test", LastActivityTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(500)}, SlideMessages: page("page2", true, 500, 450)}, pages: map[string]*slidetypes.SlideMessages{"page2": page("page3", true, 400, 350), "page3": page("end", false, 300, 250)}}
	b.api = f
	return b, f, r
}

func TestRecoveryPaginatesUntilDurableAnchor(t *testing.T) {
	b, f, r := fixture()
	_, err := b.syncInbox(context.Background(), map[string]int64{"thread": 300})
	if err != nil {
		t.Fatal(err)
	}
	if f.pageCalls != 2 || r.count("messages") != 3 || r.count("thread_synced") != 1 || r.count("conversation") != 1 {
		t.Fatalf("unexpected sync results: pages=%d messages=%d checkpoints=%d", f.pageCalls, r.count("messages"), r.count("thread_synced"))
	}
}
func TestIncompleteRecoveryDoesNotAdvanceAnchor(t *testing.T) {
	b, f, r := fixture()
	f.failPage = true
	_, err := b.syncInbox(context.Background(), map[string]int64{"thread": 300})
	if err == nil {
		t.Fatal("expected failure")
	}
	if r.count("thread_synced") != 0 {
		t.Fatal("incomplete sync advanced its anchor")
	}
}
func TestRepeatedCursorFailsWithoutCheckpoint(t *testing.T) {
	b, f, r := fixture()
	f.pages["page2"] = page("page2", true, 400)
	_, err := b.syncInbox(context.Background(), map[string]int64{"thread": 300})
	if err == nil || r.count("thread_synced") != 0 {
		t.Fatal("repeated cursor was accepted")
	}
}
func TestNewConversationLoadsRecentPageOnly(t *testing.T) {
	b, f, r := fixture()
	_, err := b.syncInbox(context.Background(), nil)
	if err != nil || f.pageCalls != 0 || r.count("thread_synced") != 1 {
		t.Fatalf("unexpected first sync: %v", err)
	}
}

func TestFirstSyncUsesMailboxSnapshotWithoutFetchingEveryHistory(t *testing.T) {
	b, api, sink := fixture()
	api.thread.SlideMessages = nil
	if _, err := b.syncInbox(context.Background(), nil); err != nil {
		t.Fatal(err)
	}
	if api.threadCalls != 0 || api.pageCalls != 0 {
		t.Fatal("first sync fetched history before a conversation was opened")
	}
	if sink.count("conversation") != 1 || sink.count("thread_synced") != 1 {
		t.Fatal("first sync did not establish the inbox baseline")
	}
}

func TestUnchangedConversationDoesNotRefetchHistory(t *testing.T) {
	b, api, sink := fixture()
	if _, err := b.syncInbox(context.Background(), map[string]int64{"thread": 500}); err != nil {
		t.Fatal(err)
	}
	if api.threadCalls != 0 || api.pageCalls != 0 || sink.count("messages") != 0 {
		t.Fatal("unchanged conversation fetched history")
	}
}
func TestSendingContinuesWhileMailboxSyncIsWaiting(t *testing.T) {
	b, api, sink := fixture()
	api.mailboxEntered = make(chan struct{})
	b.connected.Store(true)
	if _, err := b.Handle(context.Background(), "sync", json.RawMessage(`{"anchors":{}}`)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-api.mailboxEntered:
	case <-time.After(time.Second):
		t.Fatal("background sync did not start")
	}
	_, err := b.Handle(context.Background(), "send", json.RawMessage(`{"threadID":"thread","clientID":"123","text":"synthetic test"}`))
	var fault *wire.Fault
	if !errors.As(err, &fault) || fault.Code != "send_unknown" || api.sendCalls != 1 {
		t.Fatalf("send was blocked by sync: %v", err)
	}
	b.Close()
	if b.syncDone != nil || sink.count("sync_finished") != 0 {
		t.Fatal("cancelled sync outlived the connection")
	}
}

func TestBackgroundSyncReportsCompletion(t *testing.T) {
	b, _, sink := fixture()
	if _, err := b.Handle(context.Background(), "sync", json.RawMessage(`{"anchors":{}}`)); err != nil {
		t.Fatal(err)
	}
	select {
	case <-b.syncDone:
	case <-time.After(time.Second):
		t.Fatal("background sync did not finish")
	}
	if sink.count("sync_finished") != 1 || sink.count("thread_synced") != 1 {
		t.Fatal("sync completion was not delivered")
	}
	b.Close()
}

func TestSendNetworkFailureIsUncertainAndNeverRetried(t *testing.T) {
	b, f, _ := fixture()
	b.connected.Store(true)
	f.sendError = errors.New("request body with secrets must not escape")
	_, err := b.send(context.Background(), json.RawMessage(`{"threadID":"thread","clientID":"123","text":"hello"}`))
	var fault *wire.Fault
	if !errors.As(err, &fault) || fault.Code != "send_unknown" || f.sendCalls != 1 {
		t.Fatalf("unexpected result: %v calls=%d", err, f.sendCalls)
	}
}
func TestOfflineSendNeverEntersNetwork(t *testing.T) {
	b, f, _ := fixture()
	_, err := b.send(context.Background(), json.RawMessage(`{"threadID":"thread","clientID":"123","text":"hello"}`))
	var fault *wire.Fault
	if !errors.As(err, &fault) || fault.Code != "not_sent" || f.sendCalls != 0 {
		t.Fatalf("unexpected result: %v", err)
	}
}
func TestMessageNormalizationKeepsIdentityAndThread(t *testing.T) {
	m := convertMessage(&slidetypes.Message{ID: "server", ThreadFBID: "thread", SenderFBID: 2, OfflineThreadingID: "123", TextBody: "Hello 👋"}, "", "2")
	if m.ID != "server" || m.ThreadID != "thread" || !m.IsOwn || m.ClientID != "123" {
		t.Fatalf("bad normalization: %+v", m)
	}
}

func TestThreadNormalizationUsesOwnReadWatermark(t *testing.T) {
	thread := &slidetypes.ThreadInfo{
		ID: "thread", ThreadTitle: "Test",
		LastActivityTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(500)},
		SlideReadReceipts: []slidetypes.ReadReceipt{
			{ParticipantFBID: 2, WatermarkTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(300)}},
			{ParticipantFBID: 3, WatermarkTimestampMS: jsontime.UnixMilliString{Time: time.UnixMilli(500)}},
		},
	}
	conversation := convertThread(thread, "2")
	if !conversation.Unread || conversation.ReadAt == nil || *conversation.ReadAt != 300 {
		t.Fatalf("read watermark does not belong to the viewer: %+v", conversation)
	}
	conversation = convertThread(thread, "4")
	if conversation.ReadAt != nil {
		t.Fatal("missing viewer receipt must remain unknown")
	}
}
