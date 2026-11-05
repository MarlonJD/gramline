package instagram

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
)

func TestDirectMediaConversionKeepsAlbumsAndRejectsUntrustedURLs(t *testing.T) {
	message := convertMessage(&slidetypes.Message{ID: "m", Content: slidetypes.MessageContentWrapper{Content: &slidetypes.MessageContentMultiMedia{Attachments: []*slidetypes.Attachment{
		{AttachmentFBID: "photo", AttachmentCDNURL: "https://s.cdninstagram.com/photo.jpg", PreviewWidth: 400, PreviewHeight: 600},
		{AttachmentFBID: "video", AttachmentType: int(table.AttachmentTypeVideo), AttachmentCDNURL: "https://s.fbcdn.net/video.mp4", PreviewCDNURL: "https://s.fbcdn.net/cover.jpg"},
		nil,
		{AttachmentFBID: "invalid", AttachmentCDNURL: "https://example.org/image.jpg", PreviewCDNURL: "file:///private/image.jpg"},
	}}}}, "thread", "me")
	media := message.DirectMedia
	if message.Kind != "direct_media" || media == nil || len(media.Items) != 4 {
		t.Fatal("lost album structure")
	}
	if media.Items[0].ID != "photo" || media.Items[0].Height != 600 || media.Items[1].Kind != "video" || media.Items[1].PreviewURL == "" {
		t.Fatal("lost media metadata")
	}
	if media.Items[2].URL != "" || media.Items[3].URL != "" || media.Items[3].PreviewURL != "" {
		t.Fatal("unavailable positions or URL validation failed")
	}
}

func TestRestrictedRavenMediaNeverExportsDownloadLocations(t *testing.T) {
	for _, mode := range []slidetypes.RavenViewMode{0, 1, 2, 99} {
		for _, video := range []bool{false, true} {
			content := &slidetypes.MessageContentRavenImage{ViewMode: mode, Attachment: &slidetypes.Attachment{AttachmentCDNURL: "https://s.fbcdn.net/private.jpg", PreviewCDNURL: "https://s.fbcdn.net/preview.jpg"}}
			message := &slidetypes.Message{Content: slidetypes.MessageContentWrapper{Content: content}}
			if video {
				converted := slidetypes.MessageContentRavenVideo(*content)
				message.Content.Content = &converted
			}
			result := directMediaFromMessage(message)
			raw, err := json.Marshal(result)
			if err != nil || result.ViewMode == nil || *result.ViewMode != int(mode) {
				t.Fatal("lost view mode")
			}
			if mode != 2 && (len(result.Items) != 0 || strings.Contains(string(raw), "fbcdn")) {
				t.Fatal("restricted media leaked a download address")
			}
			if mode == 2 && (len(result.Items) != 1 || result.Items[0].URL == "") {
				t.Fatal("keep-in-chat media was hidden")
			}
		}
	}
	result := directMediaFromMessage(&slidetypes.Message{Content: slidetypes.MessageContentWrapper{Content: &slidetypes.MessageContentRavenImage{ViewMode: 1}}})
	if result == nil || len(result.Items) != 0 {
		t.Fatal("missing attachment was not retained as restricted media")
	}
}

func TestMessageMediaRefreshUsesIdentityAndEnforcesCurrentViewMode(t *testing.T) {
	b, api, _ := fixture()
	message := &slidetypes.Message{ID: "target", Content: slidetypes.MessageContentWrapper{Content: &slidetypes.MessageContentImage{Attachments: []*slidetypes.Attachment{{AttachmentCDNURL: "https://s.fbcdn.net/fresh.jpg"}}}}}
	api.thread.SlideMessages.Edges = []slidetypes.Node[*slidetypes.Message]{{Node: message}}
	value, err := b.fetchMessageMedia(context.Background(), json.RawMessage(`{"threadID":"thread","messageID":"target"}`))
	if err != nil || value.(*DirectMedia).Items[0].URL == "" {
		t.Fatal("could not refresh recent media")
	}
	api.pages["before:newer"] = api.thread.SlideMessages
	message.Content.Content = &slidetypes.MessageContentRavenImage{ViewMode: 0, Attachment: &slidetypes.Attachment{AttachmentCDNURL: "https://s.fbcdn.net/restricted.jpg"}}
	value, err = b.fetchMessageMedia(context.Background(), json.RawMessage(`{"threadID":"thread","messageID":"target","newerMessageID":"newer"}`))
	if err != nil || len(value.(*DirectMedia).Items) != 0 {
		t.Fatal("refresh failed to enforce view mode")
	}
	if _, err = b.fetchMessageMedia(context.Background(), json.RawMessage(`{"threadID":"thread","messageID":"missing"}`)); err == nil {
		t.Fatal("returned another message's media")
	}
	b.api = nil
	if _, err = b.fetchMessageMedia(context.Background(), json.RawMessage(`{"threadID":"thread","messageID":"target"}`)); err == nil {
		t.Fatal("unauthenticated refresh succeeded")
	}
}
