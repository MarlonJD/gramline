package slidetypes

// ThreadTheme is included by IGDThreadDetailQuery when chat themes are enabled.
type ThreadTheme struct {
	AppColorMode                 string   `json:"app_color_mode"`
	FallbackColor                string   `json:"fallback_color"`
	GradientColors               []string `json:"gradient_colors"`
	OutboundMessageTextColor     string   `json:"outbound_message_text_color"`
	InboundMessageTextColor      string   `json:"inbound_message_text_color"`
	IncomingMessageBubbleColor   string   `json:"incoming_message_bubble_color"`
	NavigationBarColor           string   `json:"navigation_bar_color"`
	NavigationBarIconColor       string   `json:"navigation_bar_icon_color"`
	NavigationBarTitleColor      string   `json:"navigation_bar_title_color"`
	SolidComposerBackgroundColor string   `json:"solid_composer_background_color"`
	ComposerInputBackgroundColor string   `json:"composer_input_background_color"`
	ComposerSecondaryButtonColor string   `json:"composer_secondary_button_color"`
	ThreadBackgroundColor        string   `json:"thread_background_color"`
	ThreadBackgroundAsset        struct {
		URL480  string `json:"url_480"`
		URL1024 string `json:"url_1024"`
	} `json:"thread_background_asset"`
	AlternativeThemes []*ThreadTheme `json:"alternative_themes"`
}
