import Foundation

public struct SharedPost: Codable, Sendable, Equatable {
    public var mediaID: String
    public var shortcode: String
    public var url: String
    public var kind: String
    public var author: String
    public var title: String
    public var caption: String
    public var previewURL: String
    public var selectedItemID: String

    public init(mediaID: String, shortcode: String, url: String, kind: String = "post", author: String = "", title: String = "", caption: String = "", previewURL: String = "", selectedItemID: String = "") {
        self.mediaID = mediaID; self.shortcode = shortcode; self.url = url; self.kind = kind
        self.author = author; self.title = title; self.caption = caption; self.previewURL = previewURL; self.selectedItemID = selectedItemID
    }
    public var label: String { kind == "reel" ? "Reel" : "Post" }
    public var instagramURL: URL? {
        guard let value = URL(string: url), value.scheme == "https", value.user == nil,
              ["instagram.com", "www.instagram.com"].contains(value.host ?? ""), value.port == nil else { return nil }
        return value
    }
}

public struct SharedMediaItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: String
    public var url: String
    public var previewURL: String
    public var width: Int
    public var height: Int
}

public struct SharedPostContent: Codable, Sendable, Equatable {
    public var author: String
    public var caption: String
    public var items: [SharedMediaItem]
    public var selectedIndex: Int
}
