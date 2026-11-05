package instagram

import (
	"context"
	"encoding/json"
	"math/big"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/responses"
	"insta-dm/core/internal/wire"
)

// SharedPost keeps stable identity separate from expiring CDN locations.
type SharedPost struct {
	MediaID        string `json:"mediaID"`
	Shortcode      string `json:"shortcode"`
	URL            string `json:"url"`
	Kind           string `json:"kind"`
	Author         string `json:"author"`
	Title          string `json:"title"`
	Caption        string `json:"caption"`
	PreviewURL     string `json:"previewURL"`
	SelectedItemID string `json:"selectedItemID"`
}

type SharedMediaItem struct {
	ID         string `json:"id"`
	Kind       string `json:"kind"`
	URL        string `json:"url"`
	PreviewURL string `json:"previewURL"`
	Width      int    `json:"width"`
	Height     int    `json:"height"`
}

type SharedPostContent struct {
	Author        string            `json:"author"`
	Caption       string            `json:"caption"`
	Items         []SharedMediaItem `json:"items"`
	SelectedIndex int               `json:"selectedIndex"`
}

var postPath = regexp.MustCompile(`^/(p|reel|reels)/([A-Za-z0-9_-]+)/?$`)

func parsePostURL(raw string) (*url.URL, string, string) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, "", ""
	}
	if u.Scheme == "https" && (u.Host == "l.instagram.com" || u.Host == "l.facebook.com") {
		u, err = url.Parse(u.Query().Get("u"))
		if err != nil {
			return nil, "", ""
		}
	}
	if u.Scheme != "https" || u.User != nil || (u.Host != "instagram.com" && u.Host != "www.instagram.com") {
		return nil, "", ""
	}
	parts := postPath.FindStringSubmatch(u.Path)
	if parts == nil || len(parts[2]) > 16 {
		return nil, "", ""
	}
	kind := "post"
	if parts[1] != "p" {
		kind = "reel"
	}
	return u, parts[2], kind
}

func shortcodeID(code string) string {
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
	id := new(big.Int)
	for _, ch := range code {
		n := strings.IndexRune(alphabet, ch)
		if n < 0 {
			return ""
		}
		id.Lsh(id, 6).Add(id, big.NewInt(int64(n)))
	}
	if id.Sign() <= 0 || !id.IsInt64() {
		return ""
	}
	return id.String()
}

func numericMediaID(id string) string {
	id = strings.SplitN(id, "_", 2)[0]
	if n, err := strconv.ParseInt(id, 10, 64); err == nil && n > 0 {
		return id
	}
	return ""
}

func sharedPostFromMessage(message *slidetypes.Message) *SharedPost {
	content, ok := message.Content.Content.(*slidetypes.MessageContentXMA)
	if !ok || content == nil || content.XMA == nil {
		return nil
	}
	xma := content.XMA
	u, code, kind := parsePostURL(xma.TargetURL)
	if u == nil {
		for _, cta := range xma.CTAButtons {
			if cta != nil {
				u, code, kind = parsePostURL(cta.ActionURL)
			}
			if u != nil {
				break
			}
		}
	}
	if u == nil {
		return nil
	}
	mediaID := numericMediaID(xma.TargetID)
	if mediaID == "" {
		mediaID = shortcodeID(code)
	}
	childID := numericMediaID(u.Query().Get("carousel_share_child_media_id"))
	// Drop tracking queries while retaining the selected carousel child.
	u.RawQuery = ""
	u.Fragment = ""
	if childID != "" {
		u.RawQuery = url.Values{"carousel_share_child_media_id": {childID}}.Encode()
	}
	post := &SharedPost{MediaID: mediaID, Shortcode: code, URL: u.String(), Kind: kind,
		Author: xma.HeaderTitleText, Title: xma.TitleText, Caption: xma.CaptionBodyText, SelectedItemID: childID}
	if post.Title == "" {
		post.Title = xma.XMATitle
	}
	if post.Caption == "" {
		post.Caption = xma.SubtitleText
	}
	preview := xma.PreviewImage
	if preview == nil {
		preview = xma.XMAPreviewImage
	}
	if preview != nil {
		post.PreviewURL = safeCDNURL(preview.URL)
		if post.PreviewURL == "" {
			post.PreviewURL = safeCDNURL(preview.FallbackURL)
		}
	}
	return post
}

func safeCDNURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || (u.Port() != "" && u.Port() != "443") {
		return ""
	}
	host := strings.ToLower(u.Hostname())
	for _, domain := range []string{"cdninstagram.com", "fbcdn.net", "instagram.com"} {
		if host == domain || strings.HasSuffix(host, "."+domain) {
			return raw
		}
	}
	return ""
}

func (b *Backend) fetchSharedPost(ctx context.Context, data json.RawMessage) (any, error) {
	if err := b.requireClient(); err != nil {
		return nil, err
	}
	var input SharedPost
	if json.Unmarshal(data, &input) != nil {
		return nil, invalid()
	}
	u, code, _ := parsePostURL(input.URL)
	if u == nil {
		return nil, invalid()
	}
	mediaID := numericMediaID(input.MediaID)
	if mediaID == "" {
		mediaID = shortcodeID(code)
	}
	if mediaID == "" {
		return nil, invalid()
	}
	response, err := b.api.FetchMedia(ctx, mediaID, code)
	if err != nil || response == nil || len(response.Items) == 0 || response.Items[0] == nil {
		return nil, postUnavailable()
	}
	return normalizePostContent(response.Items[0], input.SelectedItemID)
}

func normalizePostContent(item *responses.Items, selectedID string) (*SharedPostContent, error) {
	result := &SharedPostContent{Author: item.User.Username, Caption: item.Caption.Text, Items: []SharedMediaItem{}}
	items := item.CarouselMedia
	if len(items) == 0 {
		items = []*responses.Items{item}
	}
	for index, child := range items {
		if child == nil {
			continue
		}
		media := SharedMediaItem{ID: child.ID, Kind: "image"}
		if media.ID == "" {
			media.ID = strconv.Itoa(index)
		}
		var area int
		for _, image := range child.ImageVersions2.Candidates {
			if source := safeCDNURL(image.URL); source != "" && (media.PreviewURL == "" || image.Width*image.Height > area) {
				media.PreviewURL = source
				media.Width = image.Width
				media.Height = image.Height
				area = image.Width * image.Height
			}
		}
		media.URL = media.PreviewURL
		area = 0
		for _, video := range child.VideoVersions {
			if source := safeCDNURL(video.URL); source != "" && (media.Kind != "video" || video.Width*video.Height > area) {
				media.Kind = "video"
				media.URL = source
				media.Width = video.Width
				media.Height = video.Height
				area = video.Width * video.Height
			}
		}
		// Preserve album positions, including a child with unavailable media.
		if selectedID != "" && numericMediaID(child.ID) == selectedID {
			result.SelectedIndex = len(result.Items)
		}
		result.Items = append(result.Items, media)
	}
	if len(result.Items) == 0 {
		return nil, postUnavailable()
	}
	return result, nil
}

func postUnavailable() error {
	return &wire.Fault{Code: "media_unavailable", Message: "This post could not be loaded. It may have been removed, or Instagram may be limiting access. Try again or open it in Instagram."}
}
