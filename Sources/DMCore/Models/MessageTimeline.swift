import Foundation

/// Presentation grouping follows adjacent messages, not fixed clock buckets.
public struct MessageTimelineRow: Identifiable, Sendable {
    public var id: String { message.id }
    public let message: Message
    public let showsTimestamp: Bool
    public let startsSenderGroup: Bool
    public let showsSentStatus: Bool

    public static func make(from messages: [Message], calendar: Calendar = .current) -> [Self] {
        messages.enumerated().map { index, message in
            let previous = index > 0 ? messages[index - 1] : nil
            let separated = previous.map {
                !calendar.isDate($0.date, inSameDayAs: message.date) || message.date.timeIntervalSince($0.date) >= 5 * 60
            } ?? true
            let sameSender = previous.map {
                $0.isOwn == message.isOwn && !$0.senderID.isEmpty && $0.senderID == message.senderID
            } ?? false
            return Self(message: message, showsTimestamp: separated,
                        startsSenderGroup: separated || !sameSender,
                        showsSentStatus: index == messages.count - 1 && message.isOwn && message.status == .sent)
        }
    }
}

public enum UnreadBadge {
    public static func label(for count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 4 ? "4+" : String(count)
    }
}
