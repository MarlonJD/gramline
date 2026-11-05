package instagram

import (
	"context"
	"encoding/json"
	"testing"

	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"go.mau.fi/mautrix-meta/pkg/messagix/responses"
)

func (f *fakeAPI) FetchMedia(_ context.Context, id, code string) (*responses.FetchMediaResponse, error) {
	f.fetchedMediaID = id
	f.fetchedShortcode = code
	return f.fetchedMedia, nil
}

func TestSharedPostSurvivesMessageConversion(t *testing.T) {
	m := &slidetypes.Message{ID: "message", ThreadFBID: "thread", Content: slidetypes.MessageContentWrapper{Content: &slidetypes.MessageContentXMA{
		XMA: &slidetypes.XMAContent{TargetID: "9007199254740993_456", TargetURL: "https://l.facebook.com/l.php?u=https%3A%2F%2Fwww.instagram.com%2Freel%2FABC_%2F%3Figsh%3Dtracking",
			HeaderTitleText: "creator", CaptionBodyText: "A shared caption", XMAPreviewImage: &slidetypes.XMAPreviewImage{URL: "https://scontent.cdninstagram.com/cover.jpg"}},
	}}}
	message := convertMessage(m, "thread", "me")
	if message.Kind != "shared_post" || message.SharedPost == nil {
		t.Fatal("lost structured shared media")
	}
	post := message.SharedPost
	if post.Kind != "reel" || post.MediaID != "9007199254740993" || post.URL != "https://www.instagram.com/reel/ABC_/" || post.Caption != "A shared caption" || post.PreviewURL == "" {
		t.Fatalf("incorrect post normalization: %+v", post)
	}
	raw, _ := json.Marshal(message)
	var decoded Message
	if err := json.Unmarshal(raw, &decoded); err != nil || decoded.SharedPost.MediaID != post.MediaID {
		t.Fatal("wire precision lost")
	}
}

func TestPostParsingRejectsOtherContentAndResolvesShortcode(t *testing.T) {
	for _, raw := range []string{"http://instagram.com/p/AB/", "https://instagram.com.evil.example/p/AB/", "https://www.instagram.com/stories/person/123/", "https://user:pass@instagram.com/p/AB/", "https://instagram.com:444/p/AB/"} {
		if u, _, _ := parsePostURL(raw); u != nil {
			t.Fatalf("accepted unsupported post: %s", raw)
		}
	}
	if shortcodeID("BA") != "64" || shortcodeID("!") != "" || shortcodeID("________________") != "" {
		t.Fatal("invalid shortcode conversion")
	}
	for _, raw := range []string{"file:///etc/passwd", "https://127.0.0.1/media", "https://fbcdn.net.evil.example/a", "https://user@cdninstagram.com/a"} {
		if safeCDNURL(raw) != "" {
			t.Fatal("accepted untrusted media URL")
		}
	}
	if sharedPostFromMessage(&slidetypes.Message{}) != nil {
		t.Fatal("ordinary message became a post")
	}
}

func TestSharedPostResolvesMixedCarouselAndSelectedChild(t *testing.T) {
	b, api, _ := fixture()
	api.fetchedMedia = &responses.FetchMediaResponse{Items: []*responses.Items{{User: responses.User{Username: "author"}, Caption: responses.Caption{Text: "album"}, CarouselMedia: []*responses.Items{
		{ID: "123_77", ImageVersions2: responses.ImageVersions2{Candidates: []responses.Candidates{{URL: "https://s.cdninstagram.com/photo.jpg", Width: 100, Height: 100}}}},
		nil,
		{ID: "456_77", VideoVersions: []responses.VideoVersions{{URL: "https://s.fbcdn.net/low.mp4", Width: 100, Height: 100}, {URL: "https://s.fbcdn.net/high.mp4", Width: 720, Height: 1280}}},
		{ID: "789_77"},
	}}}}
	input, _ := json.Marshal(SharedPost{URL: "https://www.instagram.com/p/BA/", SelectedItemID: "456"})
	value, err := b.fetchSharedPost(context.Background(), input)
	if err != nil {
		t.Fatal(err)
	}
	result := value.(*SharedPostContent)
	if api.fetchedMediaID != "64" || api.fetchedShortcode != "BA" || len(result.Items) != 3 || result.SelectedIndex != 1 || result.Items[1].Kind != "video" || result.Items[1].URL != "https://s.fbcdn.net/high.mp4" || result.Items[2].URL != "" {
		t.Fatalf("incorrect carousel: %+v", result)
	}
}

func TestUnavailablePostIsSafeAndRequiresAuthentication(t *testing.T) {
	b, _, _ := fixture()
	input := json.RawMessage(`{"url":"https://www.instagram.com/p/BA/"}`)
	if _, err := b.fetchSharedPost(context.Background(), input); err == nil {
		t.Fatal("empty media response succeeded")
	}
	b.api = nil
	if _, err := b.fetchSharedPost(context.Background(), input); err == nil {
		t.Fatal("unauthenticated fetch succeeded")
	}
}
