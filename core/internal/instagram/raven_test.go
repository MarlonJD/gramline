package instagram

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"testing"
	"time"
)

type ravenCall struct {
	method, path string
	form         url.Values
}
type ravenStub struct {
	calls     []ravenCall
	responses []string
	err       error
}

func (s *ravenStub) request(_ context.Context, method, path string, form url.Values) ([]byte, int, error) {
	copy := url.Values{}
	for key, values := range form {
		copy[key] = append([]string(nil), values...)
	}
	s.calls = append(s.calls, ravenCall{method, path, copy})
	if s.err != nil {
		return nil, 0, s.err
	}
	data := s.responses[0]
	s.responses = s.responses[1:]
	return []byte(data), 200, nil
}

func TestRavenIdentityUsesSharedMessageIDAndPaginates(t *testing.T) {
	api := &ravenStub{responses: []string{
		`{"status":"ok","thread":{"items":[{"item_id":"slide","message_id":"wrong"}],"has_older":true,"oldest_cursor":"next"}}`,
		`{"status":"ok","thread":{"items":[{"item_id":"123456","message_id":"slide","visual_media":{"view_mode":"once","seen_count":0}}]}}`,
	}}
	item, err := findRaven(context.Background(), api, ravenIdentity{"42", "slide"})
	if err != nil || item.ID != "123456" || len(api.calls) != 2 {
		t.Fatalf("exact identity lookup failed: %v", err)
	}
	if api.calls[1].form.Get("cursor") != "next" || api.calls[0].method != http.MethodGet {
		t.Fatal("incorrect pagination")
	}
}

func ravenFixture(t *testing.T, mode string, seen int) *ravenItem {
	t.Helper()
	item := &ravenItem{}
	data := `{"item_id":"123","message_id":"slide","visual_media":{"view_mode":"once","seen_count":0,"playback_duration_secs":7,"media":{"media_type":1,"image_versions2":{"candidates":[{"url":"https://s.cdninstagram.com/small","width":100,"height":100},{"url":"https://s.fbcdn.net/large","width":500,"height":600},{"url":"https://evil.example/big","width":900,"height":900}]}}}}`
	if err := json.Unmarshal([]byte(data), item); err != nil {
		t.Fatal(err)
	}
	item.Visual.Mode, item.Visual.Seen = mode, &seen
	return item
}

func TestRavenEnforcesServerViewingLimits(t *testing.T) {
	for _, test := range []struct {
		mode      string
		seen      int
		available bool
	}{
		{"once", 0, true}, {"once", 1, false}, {"replayable", 0, true}, {"replayable", 1, true}, {"replayable", 2, false}, {"unknown", 0, false}, {"once", -1, false},
	} {
		item := ravenFixture(t, test.mode, test.seen)
		plan, err := planRaven(item, time.Now())
		if (err == nil) != test.available {
			t.Fatalf("mode=%s seen=%d available=%t err=%v", test.mode, test.seen, test.available, err)
		}
		if err == nil && (plan.URL != "https://s.fbcdn.net/large" || plan.Duration != 7) {
			t.Fatal("incorrect media selection")
		}
	}
	item := ravenFixture(t, "replayable", 1)
	expiry := time.Now().Add(-time.Second).UnixMicro()
	item.Visual.ReplayExpiry = &expiry
	if _, err := planRaven(item, time.Now()); err == nil {
		t.Fatal("expired replay allowed")
	}
	item = ravenFixture(t, "once", 0)
	item.Visual.Seen = nil
	if _, err := planRaven(item, time.Now()); err == nil {
		t.Fatal("missing viewing state allowed")
	}
	item = ravenFixture(t, "once", 0)
	item.Own = true
	if _, err := planRaven(item, time.Now()); err == nil {
		t.Fatal("sender consumed own media")
	}
}

func TestRavenReceiptUsesVisualEndpointWithoutRetry(t *testing.T) {
	for _, failure := range []bool{false, true} {
		api := &ravenStub{responses: []string{`{"status":"ok"}`}}
		if failure {
			api.err = errors.New("connection lost after submit")
		}
		err := acknowledgeRaven(context.Background(), api, "42", ravenFixture(t, "once", 0), "device")
		if (err != nil) != failure || len(api.calls) != 1 {
			t.Fatal("ambiguous receipt must not retry")
		}
		call := api.calls[0]
		if call.method != "POST" || call.path != "direct_v2/visual_threads/42/item_seen/" || call.form.Get("item_ids") != "[123]" || call.form.Get("target_item_type") != "raven_media" {
			t.Fatal("ordinary read receipt substituted for visual receipt")
		}
	}
}

func TestRavenReplayRechecksStateWithoutRequiringAnotherDownloadURL(t *testing.T) {
	item := ravenFixture(t, "replayable", 1)
	expiry := time.Now().Add(time.Minute).UnixMicro()
	item.Visual.ReplayExpiry = &expiry
	item.Visual.Media.Images.Candidates = nil
	if err := validateRavenView(item, time.Now()); err != nil {
		t.Fatal("already loaded media should remain eligible for the explicit replay")
	}
	if _, err := planRaven(item, time.Now()); err == nil {
		t.Fatal("a new viewer must not invent a missing download URL")
	}
	two := 2
	item.Visual.Seen = &two
	if err := validateRavenView(item, time.Now()); err == nil {
		t.Fatal("third view allowed")
	}
}

func TestRavenPreparationIsInvalidatedOnClose(t *testing.T) {
	b := New(context.Background(), nil)
	b.ravenPlan = &ravenPlan{Token: "one", expires: time.Now().Add(time.Minute)}
	b.Close()
	if b.ravenPlan != nil {
		t.Fatal("viewing token survived account teardown")
	}
}
