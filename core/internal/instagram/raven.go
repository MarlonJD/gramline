package instagram

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"time"

	"github.com/google/uuid"
	"insta-dm/core/internal/wire"
)

type ravenTransport interface {
	request(context.Context, string, string, url.Values) ([]byte, int, error)
}

type ravenItem struct {
	ID            string       `json:"item_id"`
	MessageID     string       `json:"message_id"`
	ClientContext string       `json:"client_context"`
	Own           bool         `json:"is_sent_by_viewer"`
	Visual        *ravenVisual `json:"visual_media"`
}
type ravenVisual struct {
	Mode         string  `json:"view_mode"`
	Seen         *int    `json:"seen_count"`
	ReplayExpiry *int64  `json:"replay_expiring_at_us"`
	Duration     float64 `json:"playback_duration_secs"`
	Media        struct {
		Type   int `json:"media_type"`
		Images struct {
			Candidates []ravenCandidate `json:"candidates"`
		} `json:"image_versions2"`
		Videos []ravenCandidate `json:"video_versions"`
	} `json:"media"`
}
type ravenCandidate struct {
	URL    string `json:"url"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
}
type ravenIdentity struct {
	ThreadID  string `json:"threadID"`
	MessageID string `json:"messageID"`
}
type ravenPlan struct {
	Token    string  `json:"token"`
	URL      string  `json:"url"`
	Kind     string  `json:"kind"`
	Seen     int     `json:"seenCount"`
	Mode     string  `json:"viewMode"`
	Duration float64 `json:"duration"`
	identity ravenIdentity
	itemID   string
	expires  time.Time
}

func ravenUnavailable() error {
	return &wire.Fault{Code: "raven_unavailable", Message: "This disappearing media is no longer available to view."}
}

func findRaven(ctx context.Context, api ravenTransport, identity ravenIdentity) (*ravenItem, error) {
	params := url.Values{"visual_message_return_type": {"unseen"}, "limit": {"100"}, "direction": {"older"}}
	for page := 0; page < 5; page++ {
		data, _, err := api.request(ctx, http.MethodGet, "direct_v2/threads/"+url.PathEscape(identity.ThreadID)+"/", params)
		if err != nil {
			return nil, &wire.Fault{Code: "raven_load", Message: "Could not load this disappearing media. Try again when connected."}
		}
		var response struct {
			Status string `json:"status"`
			Thread struct {
				Items    []ravenItem `json:"items"`
				Cursor   string      `json:"oldest_cursor"`
				HasOlder bool        `json:"has_older"`
			} `json:"thread"`
		}
		if json.Unmarshal(data, &response) != nil || response.Status != "ok" {
			return nil, &wire.Fault{Code: "raven_response", Message: "Instagram returned an unsupported disappearing-media response."}
		}
		for _, item := range response.Thread.Items {
			// Native item IDs and Slide message IDs are different namespaces.
			// Match the server's shared message_id exactly, never by timestamp.
			if item.MessageID == identity.MessageID {
				return &item, nil
			}
		}
		if !response.Thread.HasOlder || response.Thread.Cursor == "" || response.Thread.Cursor == params.Get("cursor") {
			break
		}
		params.Set("cursor", response.Thread.Cursor)
	}
	return nil, ravenUnavailable()
}

func planRaven(item *ravenItem, now time.Time) (*ravenPlan, error) {
	if err := validateRavenView(item, now); err != nil {
		return nil, err
	}
	v := item.Visual
	plan := &ravenPlan{Token: uuid.NewString(), Kind: "image", Seen: *v.Seen, Mode: v.Mode, Duration: v.Duration, itemID: item.ID, expires: now.Add(2 * time.Minute)}
	candidates := v.Media.Images.Candidates
	if v.Media.Type == 2 {
		plan.Kind, candidates = "video", v.Media.Videos
	} else if v.Media.Type != 1 {
		return nil, ravenUnavailable()
	}
	area := 0
	for _, candidate := range candidates {
		if address := safeCDNURL(candidate.URL); address != "" && (plan.URL == "" || candidate.Width*candidate.Height > area) {
			plan.URL, area = address, candidate.Width*candidate.Height
		}
	}
	if plan.URL == "" {
		return nil, ravenUnavailable()
	}
	if plan.Duration <= 0 || plan.Duration > 60 {
		plan.Duration = 10
	}
	return plan, nil
}

func validateRavenView(item *ravenItem, now time.Time) error {
	if item == nil || item.Own || item.Visual == nil || item.Visual.Seen == nil {
		return ravenUnavailable()
	}
	v := item.Visual
	limit := 0
	switch v.Mode {
	case "once":
		limit = 1
	case "replayable":
		limit = 2
	}
	if limit == 0 || *v.Seen < 0 || *v.Seen >= limit {
		return ravenUnavailable()
	}
	if v.ReplayExpiry != nil && *v.ReplayExpiry > 0 && *v.ReplayExpiry <= now.UnixMicro() {
		return ravenUnavailable()
	}
	if !decimalID(item.ID) {
		return ravenUnavailable()
	}
	return nil
}

func decimalID(value string) bool {
	if value == "" || len(value) > 128 {
		return false
	}
	for _, c := range value {
		if c < '0' || c > '9' {
			return false
		}
	}
	return true
}

func (b *Backend) prepareRaven(ctx context.Context, data json.RawMessage) (any, error) {
	if err := b.requireClient(); err != nil {
		return nil, err
	}
	var identity ravenIdentity
	if json.Unmarshal(data, &identity) != nil || !decimalID(identity.ThreadID) || identity.MessageID == "" {
		return nil, invalid()
	}
	item, err := findRaven(ctx, nativeMediaAPI{b.client}, identity)
	if err != nil {
		return nil, err
	}
	plan, err := planRaven(item, time.Now())
	if err != nil {
		return nil, err
	}
	plan.identity = identity
	// There is one media viewer. A new preparation invalidates the prior token.
	b.ravenPlan = plan
	return plan, nil
}

func (b *Backend) openRaven(ctx context.Context, data json.RawMessage) (any, error) {
	var input struct {
		Token string `json:"token"`
	}
	if json.Unmarshal(data, &input) != nil || input.Token == "" {
		return nil, invalid()
	}
	plan := b.ravenPlan
	if plan == nil || input.Token != plan.Token || time.Now().After(plan.expires) {
		return nil, &wire.Fault{Code: "raven_not_opened", Message: "This viewing request expired. Close it and open the photo again."}
	}
	b.ravenPlan = nil // A lost response must never cause this operation to replay.
	if err := b.requireClient(); err != nil {
		return nil, &wire.Fault{Code: "raven_not_opened", Message: "Reconnect before opening this media."}
	}
	api := nativeMediaAPI{b.client}
	item, err := findRaven(ctx, api, plan.identity)
	if err != nil {
		return nil, &wire.Fault{Code: "raven_not_opened", Message: "Could not recheck this media's viewing status. Close it and try again."}
	}
	err = validateRavenView(item, time.Now())
	if err != nil || item.ID != plan.itemID || *item.Visual.Seen != plan.Seen || item.Visual.Mode != plan.Mode {
		return nil, &wire.Fault{Code: "raven_not_opened", Message: "This media's viewing status changed. Close it and open it again."}
	}
	session := b.client.GetInstagramNativeSession()
	if session == nil {
		return nil, &wire.Fault{Code: "raven_not_opened", Message: "Reconnect before opening this media."}
	}
	err = acknowledgeRaven(ctx, api, plan.identity.ThreadID, item, session.Device.DeviceID)
	if err != nil {
		return nil, err
	}
	_ = b.persist(ctx)
	result := map[string]any{"seenCount": plan.Seen + 1}
	// Replay retains only the already-downloaded file in the current viewer.
	// Instagram removes URLs after the first view, but still reports replay
	// eligibility and its deadline. The second receipt rechecks that state.
	if plan.Mode == "replayable" && plan.Seen == 0 {
		after, err := findRaven(ctx, api, plan.identity)
		if err == nil && validateRavenView(after, time.Now()) == nil && *after.Visual.Seen == 1 && after.Visual.ReplayExpiry != nil && *after.Visual.ReplayExpiry > time.Now().UnixMicro() {
			plan.Token, plan.Seen, plan.URL = uuid.NewString(), 1, ""
			plan.expires = time.UnixMicro(*after.Visual.ReplayExpiry)
			if limit := time.Now().Add(2 * time.Minute); plan.expires.After(limit) {
				plan.expires = limit
			}
			b.ravenPlan = plan
			result["replayToken"], result["replayDeadline"] = plan.Token, plan.expires.UnixMilli()
		}
	}
	return result, nil
}

func acknowledgeRaven(ctx context.Context, api ravenTransport, thread string, item *ravenItem, deviceID string) error {
	// Instagram's native visual receipt uses item_ids, not the ordinary message
	// read watermark. Each explicit viewing sends one receipt, including replay.
	form := url.Values{"_uuid": {deviceID}, "item_ids": {"[" + item.ID + "]"}, "target_item_type": {"raven_media"}, "original_message_client_context": {item.ClientContext}}
	data, _, err := api.request(ctx, http.MethodPost, "direct_v2/visual_threads/"+url.PathEscape(thread)+"/item_seen/", form)
	var response struct {
		Status string `json:"status"`
	}
	if err != nil || json.Unmarshal(data, &response) != nil || response.Status != "ok" {
		return &wire.Fault{Code: "raven_unknown", Message: "Instagram did not confirm opening this media. It will not be opened again automatically; check its status in Instagram."}
	}
	return nil
}
