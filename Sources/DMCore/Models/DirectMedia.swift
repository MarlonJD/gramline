import Foundation

public struct DirectMedia: Codable, Sendable, Equatable {
    public var kind: String
    public var viewMode: Int?
    public var items: [SharedMediaItem]
    public var viewState: String?
    public var isRestricted: Bool { viewMode.map { $0 != 2 } ?? false }
    public var label: String { kind == "video" ? "Video" : "Photo" }
    public var canOpenRestricted: Bool { [0, 1].contains(viewMode ?? -1) && viewState == nil }
    public var restriction: String? {
        guard isRestricted else { return nil }
        switch viewState {
        case "opened": return "Opened"
        case "replayed": return "Replayed"
        case "unavailable": return "No longer available"
        default: break
        }
        switch viewMode {
        case 0: return "View once"
        case 1: return "Replay allowed"
        default: return "Open in Instagram on your phone"
        }
    }
}
