import Foundation

public struct ChatTheme: Codable, Sendable, Equatable {
    public var normal: ThemePalette?
    public var dark: ThemePalette?
    public func palette(darkMode: Bool) -> ThemePalette? { darkMode ? dark ?? normal : normal ?? dark }
}

public struct ThemePalette: Codable, Sendable, Equatable {
    public var backgroundURL: String?
    public var backgroundColor: String?
    public var outgoingColors: [String]
    public var outgoingTextColor: String?
    public var incomingColor: String?
    public var incomingTextColor: String?
    public var navigationColor: String?
    public var navigationTextColor: String?
    public var composerColor: String?
    public var composerInputColor: String?
    public var composerTextColor: String?
}
