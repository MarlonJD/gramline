package instagram

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/instameow"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/httpclient"
	"insta-dm/core/internal/wire"
)

const maxFileBytes = 25_000_000
const maxImageBytes = 8_000_000

type instagramAPI struct{ *instameow.Client }

func (a *instagramAPI) UploadMedia(ctx context.Context, thread int64, media *httpclient.MercuryUploadMedia) (int64, error) {
	response, err := a.GetHTTP().SendMercuryUploadRequest(ctx, thread, media)
	if err != nil {
		return 0, err
	}
	if response == nil || response.Payload.RealMetadata == nil {
		return 0, fmt.Errorf("missing media metadata")
	}
	id := response.Payload.RealMetadata.GetFbId()
	if id <= 0 {
		return 0, fmt.Errorf("missing media identifier")
	}
	return id, nil
}

type mediaInput struct {
	ThreadID   string     `json:"threadID"`
	ClientID   string     `json:"clientID"`
	Path       string     `json:"path"`
	Attachment Attachment `json:"attachment"`
}

func (b *Backend) sendMedia(ctx context.Context, data json.RawMessage) (any, error) {
	if err := b.requireClient(); err != nil {
		return nil, err
	}
	var input mediaInput
	if json.Unmarshal(data, &input) != nil || input.ThreadID == "" || input.Attachment.ID == "" || input.Attachment.Filename == "" {
		return nil, invalid()
	}
	if id, err := strconv.ParseInt(input.ClientID, 10, 64); err != nil || id <= 0 {
		return nil, invalid()
	}
	if !b.connected.Load() {
		return nil, mediaNotSent("The attachment was not sent because Instagram is disconnected.")
	}
	media, err := readMedia(input)
	if err != nil {
		return nil, err
	}
	// The upload referer uses the messaging thread key. The final send uses the IG thread ID.
	thread, err := b.api.GetThread(ctx, slidetypes.MakeGetThreadInfoRequest(input.ThreadID))
	if err != nil || thread == nil || thread.ThreadInfo.AsIGDirectThread == nil {
		return nil, mediaNotSent("Could not prepare this conversation for an attachment. Try refreshing it.")
	}
	info := thread.ThreadInfo.AsIGDirectThread
	threadKey := info.ThreadKey
	if threadKey == 0 {
		threadKey, _ = strconv.ParseInt(info.ThreadFBID, 10, 64)
	}
	if threadKey <= 0 {
		return nil, mediaNotSent("Instagram did not return a valid conversation for this attachment.")
	}
	attachmentID, err := b.api.UploadMedia(ctx, threadKey, media)
	if err != nil || attachmentID <= 0 {
		return nil, mediaNotSent("Instagram could not upload this attachment. Check the file type, size and connection, then try again.")
	}
	if ctx.Err() != nil {
		return nil, mediaNotSent("The upload timed out before the attachment was sent.")
	}
	response, err := b.api.SendMedia(ctx, &slidetypes.SendMediaRequest{ThreadID: input.ThreadID, OfflineThreadingID: input.ClientID, AttachmentFBID: strconv.FormatInt(attachmentID, 10)})
	// Uploading is separate from committing a message. Only a failed commit is uncertain.
	if err != nil || response == nil || response.Message.ID == "" {
		return nil, &wire.Fault{Code: "send_unknown", Message: "Attachment delivery could not be confirmed. Refresh this conversation before sending it again."}
	}
	input.Attachment.MimeType = media.MimeType
	input.Attachment.ByteCount = len(media.MediaData)
	kind := "file"
	if strings.HasPrefix(media.MimeType, "image/") {
		kind = "image"
	}
	m := Message{ID: response.Message.ID, ThreadID: input.ThreadID, ClientID: input.ClientID, SenderID: b.ownID(), Text: input.Attachment.Filename, Timestamp: response.Message.TimestampMS.UnixMilli(), IsOwn: true, Status: "sent", Kind: kind, Attachment: &input.Attachment}
	if m.Timestamp <= 0 {
		m.Timestamp = time.Now().UnixMilli()
	}
	return m, nil
}

func readMedia(input mediaInput) (*httpclient.MercuryUploadMedia, error) {
	if !filepath.IsAbs(input.Path) {
		return nil, invalid()
	}
	info, err := os.Lstat(input.Path)
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > maxFileBytes {
		return nil, mediaNotSent("The attachment is missing, empty or larger than 25 MB. Attach the file again.")
	}
	file, err := os.Open(input.Path)
	if err != nil {
		return nil, mediaNotSent("The attachment could not be opened. Attach the file again.")
	}
	defer file.Close()
	bytes, err := io.ReadAll(io.LimitReader(file, maxFileBytes+1))
	if err != nil || len(bytes) == 0 || len(bytes) > maxFileBytes {
		return nil, mediaNotSent("The attachment could not be read within the 25 MB limit.")
	}
	contentType, _, err := mime.ParseMediaType(input.Attachment.MimeType)
	if err != nil {
		return nil, invalid()
	}
	detected := http.DetectContentType(bytes)
	if strings.HasPrefix(detected, "image/") {
		contentType = detected
	}
	if strings.HasPrefix(contentType, "image/") {
		switch contentType {
		case "image/jpeg", "image/png", "image/gif", "image/webp":
		default:
			return nil, mediaNotSent("Convert this image to PNG or JPEG before sending.")
		}
		if detected != contentType {
			return nil, mediaNotSent("This image file is not valid. Attach another image.")
		}
		if len(bytes) > maxImageBytes {
			return nil, mediaNotSent("Photos must be no larger than 8 MB.")
		}
	}
	filename := strings.Map(func(r rune) rune {
		if r < 32 || r == '"' || r == '\\' || r == 127 {
			return '_'
		}
		return r
	}, filepath.Base(input.Attachment.Filename))
	return &httpclient.MercuryUploadMedia{Filename: filename, MimeType: contentType, MediaData: bytes}, nil
}

func mediaNotSent(message string) error { return &wire.Fault{Code: "not_sent", Message: message} }
