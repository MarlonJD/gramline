import Foundation

public struct MessageAttachment: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var filename: String
    public var mimeType: String
    public var byteCount: Int
    public var localPath: String?
    public var isImage: Bool { mimeType.hasPrefix("image/") }
    public var localURL: URL? { localPath.map { URL(fileURLWithPath: $0) } }
    public init(id: String, filename: String, mimeType: String, byteCount: Int, localPath: String? = nil) {
        self.id = id; self.filename = filename; self.mimeType = mimeType; self.byteCount = byteCount; self.localPath = localPath
    }
}
