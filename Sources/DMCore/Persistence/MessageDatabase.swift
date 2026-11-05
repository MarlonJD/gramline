import CSQLite
import Foundation

/// The main actor is the only database writer. Each Instagram account has its own file.
@MainActor
public final class MessageDatabase {
    private var connection: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard sqlite3_open_v2(url.path, &connection, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let connection { sqlite3_close(connection) }
            connection = nil
            throw CoreError(code: "database", message: "Could not open local message history.")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
        try execute("PRAGMA busy_timeout=5000")
        try execute("CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, updated INTEGER NOT NULL, payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, thread TEXT NOT NULL, client TEXT NOT NULL, own INTEGER NOT NULL, timestamp INTEGER NOT NULL, payload TEXT NOT NULL)")
        try execute("CREATE INDEX IF NOT EXISTS messages_by_thread ON messages(thread, timestamp)")
        try execute("CREATE INDEX IF NOT EXISTS messages_by_client ON messages(thread, client, own)")
        try execute("CREATE TABLE IF NOT EXISTS sync_anchors (thread TEXT PRIMARY KEY, timestamp INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS drafts (thread TEXT PRIMARY KEY, text TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS read_watermarks (thread TEXT PRIMARY KEY, timestamp INTEGER NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS attachment_drafts (thread TEXT PRIMARY KEY, payload TEXT NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS raven_views (thread TEXT NOT NULL, message TEXT NOT NULL, reserved_count INTEGER NOT NULL, PRIMARY KEY(thread,message))")
        try recoverInterruptedSends()
    }

    isolated deinit { if let connection { sqlite3_close(connection) } }

    public func conversations() throws -> [Conversation] {
        try payloads("SELECT payload FROM conversations ORDER BY updated DESC", as: Conversation.self)
    }

    public func messages(in thread: String) throws -> [Message] {
        try payloads("SELECT payload FROM messages WHERE thread=? ORDER BY timestamp, id", values: [.text(thread)], as: Message.self)
    }

    public func upsert(_ conversation: Conversation) throws {
        var merged = conversation
        if let readAt = conversation.readAt { try saveReadWatermark(conversation.id, timestamp: readAt) }
        if !conversation.unread { try saveReadWatermark(conversation.id, timestamp: conversation.updatedAt) }
        if let current: Conversation = try payloads("SELECT payload FROM conversations WHERE id=?", values: [.text(conversation.id)], as: Conversation.self).first {
            if conversation.themeLoaded != true { merged.theme = current.theme; merged.themeLoaded = current.themeLoaded }
            if current.updatedAt > conversation.updatedAt {
                merged.updatedAt = current.updatedAt; merged.preview = current.preview; merged.unread = current.unread
            }
        }
        if let readAt = try readWatermark(conversation.id), readAt >= merged.updatedAt { merged.unread = false }
        try execute("INSERT INTO conversations VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET updated=excluded.updated,payload=excluded.payload",
                    [.text(merged.id), .int(merged.updatedAt), .text(try json(merged))])
    }

    /// Reconciles optimistic sends with server echoes, including echo-before-response races.
    @discardableResult
    public func upsert(_ messages: [Message]) throws -> Set<String> {
        var inserted: Set<String> = []
        try transaction {
            for var message in messages {
                guard !message.id.isEmpty, !message.threadID.isEmpty else { continue }
                let old = try self.message(id: message.id)
                if message.directMedia?.isRestricted == true, message.directMedia?.viewMode == old?.directMedia?.viewMode {
                    message.directMedia?.viewState = old?.directMedia?.viewState
                }
                var saved = old
                if message.isOwn && !message.clientID.isEmpty && saved?.attachment?.localPath == nil {
                    saved = try payloads("SELECT payload FROM messages WHERE thread=? AND client=? AND own=1 ORDER BY timestamp LIMIT 1", values: [.text(message.threadID), .text(message.clientID)], as: Message.self).first
                }
                if let attachment = saved?.attachment, message.attachment?.localPath == nil {
                    message.attachment = attachment; message.kind = saved?.kind ?? message.kind
                }
                if old == nil { inserted.insert(message.id) }
                if message.isOwn && !message.clientID.isEmpty && message.status == .sent {
                    try execute("DELETE FROM messages WHERE thread=? AND client=? AND own=1 AND id<>?",
                                [.text(message.threadID), .text(message.clientID), .text(message.id)])
                }
                try execute("INSERT INTO messages VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,timestamp=excluded.timestamp,client=excluded.client",
                            [.text(message.id), .text(message.threadID), .text(message.clientID), .int(message.isOwn ? 1 : 0), .int(message.timestamp), .text(try json(message))])
                var conversation: Conversation = try payloads("SELECT payload FROM conversations WHERE id=?", values: [.text(message.threadID)], as: Conversation.self).first
                    ?? Conversation(id: message.threadID, title: "Instagram conversation")
                if message.timestamp >= conversation.updatedAt {
                    conversation.updatedAt = message.timestamp; conversation.preview = message.text
                    let readAt = try readWatermark(message.threadID) ?? -1
                    if old == nil && !message.isOwn && message.timestamp > readAt { conversation.unread = true }
                    try upsert(conversation)
                }
            }
        }
        return inserted
    }

    public func markSend(clientID: String, status: DeliveryStatus) throws {
        let pending: [Message] = try payloads("SELECT payload FROM messages WHERE client=? AND own=1", values: [.text(clientID)], as: Message.self)
        for var message in pending where message.status != .sent {
            message.status = status
            try execute("UPDATE messages SET payload=? WHERE id=?", [.text(try json(message)), .text(message.id)])
        }
    }

    public func editMessage(id: String, text: String) throws {
        guard var message = try message(id: id) else { return }
        message.text = text
        try execute("UPDATE messages SET payload=? WHERE id=?", [.text(try json(message)), .text(id)])
    }

    public func deleteMessage(id: String) throws { try execute("DELETE FROM messages WHERE id=?", [.text(id)]) }

    public func setRavenState(thread: String, message id: String, state: String) throws {
        guard ["opened", "replayed", "unavailable"].contains(state), var message = try message(id: id),
              message.threadID == thread, message.directMedia?.isRestricted == true else { return }
        message.directMedia?.viewState = state
        try execute("UPDATE messages SET payload=? WHERE id=?", [.text(try json(message)), .text(id)])
    }

    /// Reserve durably before submitting a visual receipt. If the process dies
    /// or the receipt response is lost, a stale server count cannot reopen it.
    public func reserveRavenView(thread: String, message: String, seenCount: Int) throws {
        guard seenCount >= 0 && seenCount < 2 else { throw CoreError(code: "raven_unavailable", message: "This media has already been viewed.") }
        try transaction {
            var reserved = 0
            try rows("SELECT reserved_count FROM raven_views WHERE thread=? AND message=?", [.text(thread), .text(message)]) { reserved = Int(sqlite3_column_int64($0, 0)) }
            guard seenCount >= reserved else {
                throw CoreError(code: "raven_pending", message: "Instagram has not confirmed the previous viewing status. Check this media in Instagram before trying again.")
            }
            try execute("INSERT INTO raven_views VALUES (?,?,?) ON CONFLICT(thread,message) DO UPDATE SET reserved_count=excluded.reserved_count",
                        [.text(thread), .text(message), .int(Int64(seenCount + 1))])
        }
    }

    /// Only release when the helper proves no receipt entered the transport.
    public func releaseUnsubmittedRavenView(thread: String, message: String, seenCount: Int) throws {
        try execute("UPDATE raven_views SET reserved_count=? WHERE thread=? AND message=? AND reserved_count=?",
                    [.int(Int64(seenCount)), .text(thread), .text(message), .int(Int64(seenCount + 1))])
    }
    public func deleteConversation(id: String) throws {
        try transaction {
            for table in ["messages", "sync_anchors", "drafts", "read_watermarks", "attachment_drafts", "raven_views"] { try execute("DELETE FROM \(table) WHERE thread=?", [.text(id)]) }
            try execute("DELETE FROM conversations WHERE id=?", [.text(id)])
        }
    }
    public func markViewed(_ thread: String) throws {
        guard var conversation: Conversation = try payloads("SELECT payload FROM conversations WHERE id=?", values: [.text(thread)], as: Conversation.self).first else { return }
        conversation.unread = false; try upsert(conversation)
    }

    /// Counts actual incoming messages, never a placeholder for an empty thread.
    public func unreadMessageCount() throws -> Int {
        var count = 0
        for conversation in try conversations() where conversation.unread {
            let readAt = try readWatermark(conversation.id) ?? -1
            try rows("SELECT COUNT(*) FROM messages WHERE thread=? AND own=0 AND timestamp>?", [.text(conversation.id), .int(readAt)]) {
                count += Int(sqlite3_column_int64($0, 0))
            }
        }
        return count
    }

    public func markRead(_ thread: String, through timestamp: Int64) throws {
        try saveReadWatermark(thread, timestamp: timestamp)
        guard var conversation: Conversation = try payloads("SELECT payload FROM conversations WHERE id=?", values: [.text(thread)], as: Conversation.self).first else { return }
        // Keep a newer incoming message unread when an older receipt arrives.
        if timestamp >= conversation.updatedAt { conversation.unread = false }
        conversation.readAt = max(conversation.readAt ?? -1, timestamp)
        try upsert(conversation)
    }

    private func saveReadWatermark(_ thread: String, timestamp: Int64) throws {
        try execute("INSERT INTO read_watermarks VALUES (?,?) ON CONFLICT(thread) DO UPDATE SET timestamp=MAX(timestamp,excluded.timestamp)", [.text(thread), .int(timestamp)])
    }
    private func readWatermark(_ thread: String) throws -> Int64? {
        var timestamp: Int64?
        try rows("SELECT timestamp FROM read_watermarks WHERE thread=?", [.text(thread)]) { timestamp = sqlite3_column_int64($0, 0) }
        return timestamp
    }

    /// A live message must never advance this watermark: earlier pages may still be missing.
    public func markSynced(thread: String, timestamp: Int64) throws {
        try execute("INSERT INTO sync_anchors VALUES (?,?) ON CONFLICT(thread) DO UPDATE SET timestamp=MAX(timestamp,excluded.timestamp)", [.text(thread), .int(timestamp)])
    }
    public func anchors() throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        try rows("SELECT thread,timestamp FROM sync_anchors") { stmt in result[columnText(stmt, 0)] = sqlite3_column_int64(stmt, 1) }
        return result
    }
    public func draft(for thread: String) throws -> String {
        var draft = ""
        try rows("SELECT text FROM drafts WHERE thread=?", [.text(thread)]) { draft = columnText($0, 0) }
        return draft
    }
    public func saveDraft(_ text: String, thread: String) throws {
        try execute("INSERT INTO drafts VALUES (?,?) ON CONFLICT(thread) DO UPDATE SET text=excluded.text", [.text(thread), .text(text)])
    }

    public func draftAttachments(for thread: String) throws -> [MessageAttachment] {
        try payloads("SELECT payload FROM attachment_drafts WHERE thread=?", values: [.text(thread)], as: [MessageAttachment].self).first ?? []
    }
    public func saveDraftAttachments(_ attachments: [MessageAttachment], thread: String) throws {
        try execute("INSERT INTO attachment_drafts VALUES (?,?) ON CONFLICT(thread) DO UPDATE SET payload=excluded.payload", [.text(thread), .text(try json(attachments))])
    }
    public func referencesAttachment(_ id: String) throws -> Bool {
        var found = false
        try rows("SELECT 1 FROM messages WHERE json_extract(payload,'$.attachment.id')=? UNION ALL SELECT 1 FROM attachment_drafts,json_each(attachment_drafts.payload) WHERE json_extract(json_each.value,'$.id')=? LIMIT 1", [.text(id), .text(id)]) { _ in found = true }
        return found
    }

    private func recoverInterruptedSends() throws {
        let messages = try payloads("SELECT payload FROM messages WHERE own=1", as: Message.self)
        try transaction {
            for message in messages where message.status == .sending { try markSend(clientID: message.clientID, status: .unknown) }
        }
    }
    private func message(id: String) throws -> Message? { try payloads("SELECT payload FROM messages WHERE id=?", values: [.text(id)], as: Message.self).first }
    private func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func payloads<T: Decodable>(_ sql: String, values: [Value] = [], as type: T.Type) throws -> [T] {
        var valuesOut: [T] = []
        try rows(sql, values) { stmt in valuesOut.append(try decoder.decode(T.self, from: Data(columnText(stmt, 0).utf8))) }
        return valuesOut
    }
    private enum Value { case text(String), int(Int64) }
    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
    private func execute(_ sql: String, _ values: [Value] = []) throws { try rows(sql, values) { _ in } }
    private func rows(_ sql: String, _ values: [Value] = [], visit: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = sqlite3_bind_text(statement, index, text, -1, transient)
            case .int(let number): result = sqlite3_bind_int64(statement, index, number)
            }
            guard result == SQLITE_OK else { throw databaseError() }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try visit(statement)
            case SQLITE_DONE: return
            default: throw databaseError()
            }
        }
    }
    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do { try work(); try execute("COMMIT") }
        catch { try? execute("ROLLBACK"); throw error }
    }
    private func databaseError() -> CoreError { CoreError(code: "database", message: "Local message history could not be saved or read. Check available disk space and folder permissions.") }
}
