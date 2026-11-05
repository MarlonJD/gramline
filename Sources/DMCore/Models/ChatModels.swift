import Foundation

public struct Account: Codable, Sendable, Equatable {
    public var id: String
    public var messagingID: String
    public var username: String
    public var name: String
    public var avatarURL: String?
    public init(id: String, messagingID: String, username: String, name: String, avatarURL: String? = nil) {
        self.id = id; self.messagingID = messagingID; self.username = username; self.name = name
        self.avatarURL = avatarURL
    }
}

public struct Conversation: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var preview: String
    public var updatedAt: Int64
    public var unread: Bool
    public var readAt: Int64?
    public var avatarURL: String?
    public var theme: ChatTheme?
    public var themeLoaded: Bool?
    public init(id: String, title: String, preview: String = "", updatedAt: Int64 = 0, unread: Bool = false, readAt: Int64? = nil, avatarURL: String? = nil) {
        self.id = id; self.title = title; self.preview = preview; self.updatedAt = updatedAt; self.unread = unread
        self.readAt = readAt
        self.avatarURL = avatarURL
    }
}

public enum DeliveryStatus: String, Codable, Sendable { case sending, sent, failed, unknown }

public struct Message: Codable, Identifiable, Sendable, Equatable {
    public var id: String
    public var threadID: String
    public var clientID: String
    public var senderID: String
    public var senderName: String
    public var text: String
    public var timestamp: Int64
    public var isOwn: Bool
    public var status: DeliveryStatus
    public var kind: String
    public var attachment: MessageAttachment?
    public var sharedPost: SharedPost?
    public var directMedia: DirectMedia?
    public var date: Date { Date(timeIntervalSince1970: Double(timestamp) / 1000) }
    public init(id: String, threadID: String, clientID: String = "", senderID: String = "", senderName: String = "", text: String, timestamp: Int64, isOwn: Bool = false, status: DeliveryStatus = .sent, kind: String = "text", attachment: MessageAttachment? = nil, sharedPost: SharedPost? = nil) {
        self.id = id; self.threadID = threadID; self.clientID = clientID; self.senderID = senderID; self.senderName = senderName
        self.text = text; self.timestamp = timestamp; self.isOwn = isOwn; self.status = status; self.kind = kind
        self.attachment = attachment
        self.sharedPost = sharedPost
    }
    public static func newClientID(now: Date = Date()) -> String {
        let milliseconds = UInt64(now.timeIntervalSince1970 * 1000)
        return String((milliseconds << 22) | UInt64.random(in: 0..<(1 << 22)))
    }
}

public struct MessagePage: Codable, Sendable {
    public var conversation: Conversation?
    public var messages: [Message]
    public var cursor: String
    public var hasMore: Bool
}

public struct LoginStep: Codable, Sendable {
    public var type: String
    public var step_id: String
    public var instructions: String
    public var user_input: Input?
    public var display_and_wait: Display?
    public struct Input: Codable, Sendable {
        public var fields: [Field]
        public var attachments: [Attachment]?
    }
    public struct Field: Codable, Sendable, Identifiable {
        public var id: String
        public var type: String
        public var name: String
        public var description: String
        public var default_value: String?
        public var optional: Bool?
        public var options: [String]?
    }
    public struct Attachment: Codable, Sendable { public var type: String?; public var content: String? }
    public struct Display: Codable, Sendable { public var type: String; public var data: String?; public var image_url: String? }
}
