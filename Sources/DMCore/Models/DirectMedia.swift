import Foundation

public struct DirectMedia: Codable, Sendable, Equatable {
    public var kind: String
    public var viewMode: Int?
    public var items: [SharedMediaItem]
    public var isRestricted: Bool { viewMode.map { $0 != 2 } ?? false }
    public var label: String { kind == "video" ? "Video" : "Photo" }
    public var restriction: String? {
        guard isRestricted else { return nil }
        switch viewMode {
        case 0: return "View once · Open in Instagram on your phone"
        case 1: return "Replay allowed · Open in Instagram on your phone"
        default: return "Open in Instagram on your phone"
        }
    }
}
