package instagram

import (
	"go.mau.fi/mautrix-meta/pkg/instameow/slidetypes"
	"regexp"
)

type ChatTheme struct {
	Normal *ThemePalette `json:"normal,omitempty"`
	Dark   *ThemePalette `json:"dark,omitempty"`
}

type ThemePalette struct {
	BackgroundURL       string   `json:"backgroundURL,omitempty"`
	BackgroundColor     string   `json:"backgroundColor,omitempty"`
	OutgoingColors      []string `json:"outgoingColors"`
	OutgoingTextColor   string   `json:"outgoingTextColor,omitempty"`
	IncomingColor       string   `json:"incomingColor,omitempty"`
	IncomingTextColor   string   `json:"incomingTextColor,omitempty"`
	NavigationColor     string   `json:"navigationColor,omitempty"`
	NavigationTextColor string   `json:"navigationTextColor,omitempty"`
	ComposerColor       string   `json:"composerColor,omitempty"`
	ComposerInputColor  string   `json:"composerInputColor,omitempty"`
	ComposerTextColor   string   `json:"composerTextColor,omitempty"`
}

var argbColor = regexp.MustCompile(`^[0-9a-fA-F]{8}$`)

func themeColor(value string) string {
	if argbColor.MatchString(value) {
		return value
	}
	return ""
}

func convertTheme(source *slidetypes.ThreadTheme) *ChatTheme {
	if source == nil {
		return nil
	}
	result := &ChatTheme{}
	sources := append([]*slidetypes.ThreadTheme{source}, source.AlternativeThemes...)
	for _, theme := range sources {
		if theme == nil {
			continue
		}
		palette := &ThemePalette{
			BackgroundURL: safeCDNURL(theme.ThreadBackgroundAsset.URL1024), BackgroundColor: themeColor(theme.ThreadBackgroundColor),
			OutgoingColors: []string{}, OutgoingTextColor: themeColor(theme.OutboundMessageTextColor),
			IncomingColor: themeColor(theme.IncomingMessageBubbleColor), IncomingTextColor: themeColor(theme.InboundMessageTextColor),
			NavigationColor: themeColor(theme.NavigationBarColor), NavigationTextColor: themeColor(theme.NavigationBarTitleColor),
			ComposerColor: themeColor(theme.SolidComposerBackgroundColor), ComposerInputColor: themeColor(theme.ComposerInputBackgroundColor),
			ComposerTextColor: themeColor(theme.ComposerSecondaryButtonColor),
		}
		if palette.BackgroundURL == "" {
			palette.BackgroundURL = safeCDNURL(theme.ThreadBackgroundAsset.URL480)
		}
		if palette.NavigationTextColor == "" {
			palette.NavigationTextColor = themeColor(theme.NavigationBarIconColor)
		}
		for _, color := range theme.GradientColors {
			if valid := themeColor(color); valid != "" {
				palette.OutgoingColors = append(palette.OutgoingColors, valid)
			}
		}
		if len(palette.OutgoingColors) == 0 {
			if color := themeColor(theme.FallbackColor); color != "" {
				palette.OutgoingColors = append(palette.OutgoingColors, color)
			}
		}
		switch theme.AppColorMode {
		case "NORMAL":
			result.Normal = palette
		case "DARK":
			result.Dark = palette
		}
	}
	if result.Normal == nil && result.Dark == nil {
		return nil
	}
	return result
}
