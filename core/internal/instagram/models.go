package instagram

import (
	"encoding/json"
	"strconv"
	"strings"
	"time"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/cookies"
	"go.mau.fi/mautrix-meta/pkg/messagix/types"
)

type Account struct {
	ID          string `json:"id"`
	MessagingID string `json:"messagingID"`
	Username    string `json:"username"`
	Name        string `json:"name"`
	AvatarURL   string `json:"avatarURL,omitempty"`
}

type Session struct {
	Version int                               `json:"version"`
	Cookies map[cookies.MetaCookieName]string `json:"cookies"`
	Native  *types.InstagramNativeSession     `json:"native,omitempty"`
	Device  *types.InstagramLoginDevice       `json:"device,omitempty"`
	Account *Account                          `json:"account,omitempty"`
	SeqID   int64                             `json:"seqID"`
	SeqTime time.Time                         `json:"seqTime"`
	Cache   json.RawMessage                   `json:"cache,omitempty"`
}

type Conversation struct {
	ID          string     `json:"id"`
	Title       string     `json:"title"`
	Preview     string     `json:"preview"`
	UpdatedAt   int64      `json:"updatedAt"`
	Unread      bool       `json:"unread"`
	ReadAt      *int64     `json:"readAt,omitempty"`
	AvatarURL   string     `json:"avatarURL,omitempty"`
	Theme       *ChatTheme `json:"theme,omitempty"`
	ThemeLoaded bool       `json:"themeLoaded,omitempty"`
}

type Message struct {
	ID          string       `json:"id"`
	ThreadID    string       `json:"threadID"`
	ClientID    string       `json:"clientID"`
	SenderID    string       `json:"senderID"`
	SenderName  string       `json:"senderName"`
	Text        string       `json:"text"`
	Timestamp   int64        `json:"timestamp"`
	IsOwn       bool         `json:"isOwn"`
	Status      string       `json:"status"`
	Kind        string       `json:"kind"`
	Attachment  *Attachment  `json:"attachment,omitempty"`
	SharedPost  *SharedPost  `json:"sharedPost,omitempty"`
	DirectMedia *DirectMedia `json:"directMedia,omitempty"`
}

type Attachment struct {
	ID        string `json:"id"`
	Filename  string `json:"filename"`
	MimeType  string `json:"mimeType"`
	ByteCount int    `json:"byteCount"`
}

type Page struct {
	Conversation *Conversation `json:"conversation,omitempty"`
	Messages     []Message     `json:"messages"`
	Cursor       string        `json:"cursor"`
	HasMore      bool          `json:"hasMore"`
}

func convertMessage(m *slidetypes.Message, thread, ownID string) Message {
	if thread == "" {
		thread = m.ThreadFBID
	}
	id := m.ID
	if id == "" {
		id = m.MessageID
	}
	text := m.TextBody
	kind := "text"
	if text == "" {
		kind = "attachment"
		text = m.IGDSnippet
		if text == "" {
			text = "Attachment · Open in Instagram"
		}
	}
	name := ""
	if m.Sender != nil {
		name = m.Sender.Name
	}
	sender := strconv.FormatInt(m.SenderFBID, 10)
	post := sharedPostFromMessage(m)
	media := directMediaFromMessage(m)
	if media != nil {
		kind, text = "direct_media", "Photo"
		if media.Kind == "video" {
			text = "Video"
		}
		if media.ViewMode != nil && *media.ViewMode != 2 {
			text = "Disappearing " + strings.ToLower(text)
		}
	}
	if post != nil {
		kind = "shared_post"
		text = "Shared a post"
		if post.Kind == "reel" {
			text = "Shared a reel"
		}
		if post.Author != "" {
			text += " · " + post.Author
		}
	}
	return Message{ID: id, ThreadID: thread, ClientID: m.OfflineThreadingID, SenderID: sender,
		SenderName: name, Text: text, Timestamp: m.TimestampMS.UnixMilli(), IsOwn: sender == ownID, Status: "sent", Kind: kind, SharedPost: post, DirectMedia: media}
}

func convertThread(t *slidetypes.ThreadInfo, ownID string) Conversation {
	title := strings.TrimSpace(t.ThreadTitle)
	if title == "" {
		var names []string
		for _, u := range t.Users {
			if u == nil {
				continue
			}
			if strconv.FormatInt(u.InteropMessagingUserFBID, 10) == ownID {
				continue
			}
			name := u.FullName
			if name == "" {
				name = u.Username
			}
			names = append(names, name)
		}
		title = strings.Join(names, ", ")
	}
	if title == "" {
		title = "Instagram conversation"
	}
	unread := t.MarkedAsUnread
	var readAt *int64
	for _, receipt := range t.SlideReadReceipts {
		if strconv.FormatInt(receipt.ParticipantFBID, 10) == ownID {
			timestamp := receipt.WatermarkTimestampMS.UnixMilli()
			readAt = &timestamp
			if receipt.WatermarkTimestampMS.Before(t.LastActivityTimestampMS.Time) {
				unread = true
			}
		}
	}
	preview := ""
	if t.SlideMessages != nil && len(t.SlideMessages.Edges) > 0 && t.SlideMessages.Edges[0].Node != nil {
		preview = convertMessage(t.SlideMessages.Edges[0].Node, t.ID, ownID).Text
	}
	avatar := safeCDNURL(t.ThreadImageURL)
	if avatar == "" && !t.IsGroup && t.ThreadSubtype != slidetypes.ThreadSubtypeGroup {
		for _, user := range t.Users {
			if user != nil && strconv.FormatInt(user.InteropMessagingUserFBID, 10) != ownID {
				avatar = safeCDNURL(user.ProfilePicURL)
				if avatar != "" {
					break
				}
			}
		}
	}
	return Conversation{ID: t.ID, Title: title, Preview: preview, UpdatedAt: t.LastActivityTimestampMS.UnixMilli(), Unread: unread, ReadAt: readAt, AvatarURL: avatar, Theme: convertTheme(t.ThemeData), ThemeLoaded: t.ThemeData != nil}
}

func convertPage(messages *slidetypes.SlideMessages, thread, ownID string) Page {
	p := Page{Messages: []Message{}}
	if messages == nil {
		return p
	}
	p.Cursor = messages.PageInfo.EndCursor
	p.HasMore = messages.PageInfo.HasNextPage
	for _, edge := range messages.Edges {
		if edge.Node != nil {
			p.Messages = append(p.Messages, convertMessage(edge.Node, thread, ownID))
		}
	}
	return p
}
