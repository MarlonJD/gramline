import Foundation

/// An explicit opening grant. Never store this payload in message history.
public struct RavenPreparation: Decodable, Sendable {
    public let token: String
    public let url: URL
    public let kind: String
    public let seenCount: Int
    public let viewMode: String
    public let duration: TimeInterval
}

public struct RavenOpenResult: Decodable, Sendable {
    public let seenCount: Int
    public let replayToken: String?
    public let replayDeadline: Int64?
}
