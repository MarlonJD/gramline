package instagram

import (
	"context"
	"encoding/json"
	"strconv"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/table"
	"insta-dm/core/internal/wire"
)

// Restricted Raven media carries its viewing mode, never a downloadable URL.
// This client does not implement Instagram's consume/replay protocol.
type DirectMedia struct {
	Kind     string            `json:"kind"`
	ViewMode *int              `json:"viewMode,omitempty"`
	Items    []SharedMediaItem `json:"items"`
}

func directMediaFromMessage(message *slidetypes.Message) *DirectMedia {
	result := &DirectMedia{Kind: "image", Items: []SharedMediaItem{}}
	var attachments []*slidetypes.Attachment
	switch content := message.Content.Content.(type) {
	case *slidetypes.MessageContentImage:
		attachments = content.Attachments
	case *slidetypes.MessageContentVideo:
		result.Kind, attachments = "video", content.Videos
	case *slidetypes.MessageContentMultiMedia:
		attachments = content.Attachments
	case *slidetypes.MessageContentRavenImage:
		mode := int(content.ViewMode)
		result.ViewMode, attachments = &mode, []*slidetypes.Attachment{content.Attachment}
	case *slidetypes.MessageContentRavenVideo:
		mode := int(content.ViewMode)
		result.Kind, result.ViewMode, attachments = "video", &mode, []*slidetypes.Attachment{content.Attachment}
	default:
		return nil
	}
	if result.ViewMode != nil && *result.ViewMode != int(slidetypes.RavenViewModeKeepInChat) {
		return result
	}
	for index, attachment := range attachments {
		item := SharedMediaItem{ID: strconv.Itoa(index), Kind: result.Kind}
		if attachment != nil {
			if attachment.AttachmentFBID != "" {
				item.ID = attachment.AttachmentFBID
			}
			if attachment.DashManifest != "" || attachment.AttachmentType == int(table.AttachmentTypeVideo) {
				item.Kind = "video"
			}
			for _, address := range []string{attachment.AttachmentCDNURL, attachment.AttachmentCDNFallbackURL} {
				if item.URL = safeCDNURL(address); item.URL != "" {
					break
				}
			}
			for _, address := range []string{attachment.PreviewCDNURL, attachment.PreviewCDNFallbackURL} {
				if item.PreviewURL = safeCDNURL(address); item.PreviewURL != "" {
					break
				}
			}
			if item.Kind == "image" && item.URL == "" {
				item.URL = item.PreviewURL
			}
			item.Width, item.Height = attachment.PreviewWidth, attachment.PreviewHeight
		}
		result.Items = append(result.Items, item)
	}
	return result
}

func (b *Backend) fetchMessageMedia(ctx context.Context, data json.RawMessage) (any, error) {
	if err := b.requireClient(); err != nil {
		return nil, err
	}
	var input struct {
		ThreadID       string `json:"threadID"`
		MessageID      string `json:"messageID"`
		NewerMessageID string `json:"newerMessageID"`
	}
	if json.Unmarshal(data, &input) != nil || input.ThreadID == "" || input.MessageID == "" {
		return nil, invalid()
	}
	var messages *slidetypes.SlideMessages
	if input.NewerMessageID == "" {
		response, err := b.api.GetThread(ctx, slidetypes.MakeGetThreadInfoRequest(input.ThreadID))
		if err != nil {
			return nil, classified(err, "Could not reload this photo or video.")
		}
		if response != nil && response.ThreadInfo.AsIGDirectThread != nil {
			messages = response.ThreadInfo.AsIGDirectThread.SlideMessages
		}
	} else {
		response, err := b.api.PaginateMessages(ctx, &slidetypes.PaginateMessagesRequest{ThreadID: input.ThreadID, OlderThanMessageID: &input.NewerMessageID, FirstN: 20, InitialMessagePageCount: 20})
		if err != nil {
			return nil, classified(err, "Could not reload this photo or video.")
		}
		if response != nil && response.ThreadInfo.AsIGDirectThread != nil {
			messages = response.ThreadInfo.AsIGDirectThread.Messages
		}
	}
	if messages != nil {
		for _, edge := range messages.Edges {
			if edge.Node == nil {
				continue
			}
			message := convertMessage(edge.Node, input.ThreadID, b.ownID())
			if message.ID == input.MessageID && message.DirectMedia != nil {
				_ = b.sink.Emit("messages", Page{Messages: []Message{message}})
				return message.DirectMedia, nil
			}
		}
	}
	return nil, &wire.Fault{Code: "media_unavailable", Message: "This photo or video is no longer available. Check it in Instagram."}
}
