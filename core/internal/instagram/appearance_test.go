package instagram

import (
	"encoding/json"
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"testing"
)

func TestConversationAvatarUsesOtherParticipantOrGroupImage(t *testing.T) {
	thread := &slidetypes.ThreadInfo{ID: "thread", Users: []*slidetypes.User{
		nil,
		{InteropMessagingUserFBID: 2, FullName: "Me", ProfilePicURL: "https://s.cdninstagram.com/me.jpg"},
		{InteropMessagingUserFBID: 3, FullName: "Other", ProfilePicURL: "https://s.cdninstagram.com/other.jpg"},
	}}
	if got := convertThread(thread, "2"); got.AvatarURL != "https://s.cdninstagram.com/other.jpg" || got.Title != "Other" {
		t.Fatalf("wrong direct avatar: %+v", got)
	}
	thread.IsGroup = true
	if convertThread(thread, "2").AvatarURL != "" {
		t.Fatal("group used one participant's picture as its identity")
	}
	thread.ThreadImageURL = "https://s.fbcdn.net/group.jpg"
	if convertThread(thread, "2").AvatarURL != thread.ThreadImageURL {
		t.Fatal("group image missing")
	}
	thread.ThreadImageURL = "https://untrusted.example/photo.jpg"
	if convertThread(thread, "2").AvatarURL != "" {
		t.Fatal("untrusted image address accepted")
	}
}

func TestThemeDecodesBothColorModesAndValidatesAssets(t *testing.T) {
	var thread slidetypes.ThreadInfo
	err := json.Unmarshal([]byte(`{"theme_data":{"app_color_mode":"NORMAL","gradient_colors":["FF0D3F61","not-a-color"],"outbound_message_text_color":"FFFFFFFF","thread_background_color":"FFB5EEFC","thread_background_asset":{"url_480":"https://s.fbcdn.net/480.jpg","url_1024":"https://s.fbcdn.net/1024.jpg"},"alternative_themes":[{"app_color_mode":"DARK","fallback_color":"FFFC62FF","navigation_bar_icon_color":"FFFFFFFF","navigation_bar_title_color":null,"thread_background_color":"FF001629","thread_background_asset":{"url_1024":"file:///tmp/not-allowed"}}]}}`), &thread)
	if err != nil {
		t.Fatal(err)
	}
	theme := convertTheme(thread.ThemeData)
	if theme == nil || theme.Normal == nil || theme.Dark == nil {
		t.Fatal("lost color mode")
	}
	if theme.Normal.BackgroundURL != "https://s.fbcdn.net/1024.jpg" || len(theme.Normal.OutgoingColors) != 1 || theme.Normal.OutgoingTextColor != "FFFFFFFF" {
		t.Fatal("light theme was not normalized")
	}
	if theme.Dark.BackgroundURL != "" || theme.Dark.NavigationTextColor != "FFFFFFFF" || len(theme.Dark.OutgoingColors) != 1 || theme.Dark.OutgoingColors[0] != "FFFC62FF" {
		t.Fatal("dark theme was not normalized")
	}
	if convertTheme(nil) != nil || convertTheme(&slidetypes.ThreadTheme{AppColorMode: "UNKNOWN"}) != nil {
		t.Fatal("invented a theme without server data")
	}
}
