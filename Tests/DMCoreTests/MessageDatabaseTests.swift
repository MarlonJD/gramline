import DMCore
import Foundation
import Testing

@MainActor
struct MessageDatabaseTests {
    private func database() throws -> (MessageDatabase, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "instadm-tests-\(UUID().uuidString)/messages.sqlite")
        return (try MessageDatabase(url: url), url)
    }
    private func message(_ id: String, client: String = "", status: DeliveryStatus = .sent, timestamp: Int64 = 100) -> Message {
        Message(id: id, threadID: "thread", clientID: client, senderID: "me", text: "Hello 👋", timestamp: timestamp, isOwn: true, status: status)
    }

    @Test func reconcilesEchoBeforeSendResponseAndHistory() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert([message("local:12", client: "12", status: .sending)])
        let echo = message("server:99", client: "12")
        try db.upsert([echo]); try db.upsert([echo]); try db.upsert([echo])
        try db.markSend(clientID: "12", status: .unknown)
        let rows = try db.messages(in: "thread")
        #expect(rows.count == 1)
        #expect(rows.first?.id == "server:99")
        #expect(rows.first?.status == .sent)
    }

    @Test func incomingClientIDCannotRemoveOurPendingSend() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert([message("local:12", client: "12", status: .sending)])
        var incoming = message("incoming", client: "12"); incoming.isOwn = false; incoming.senderID = "someone-else"
        try db.upsert([incoming])
        #expect(try db.messages(in: "thread").count == 2)
    }

    @Test func restartMakesInterruptedSendsUncertainAndKeepsDrafts() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert([message("local:15", client: "15", status: .sending)])
        try db.saveDraft("Draft with \"quotes\" and emoji 🛫", thread: "thread")
        let reopened = try MessageDatabase(url: url)
        #expect(try reopened.messages(in: "thread").first?.status == .unknown)
        #expect(try reopened.draft(for: "thread") == "Draft with \"quotes\" and emoji 🛫")
    }

    @Test func liveMessagesDoNotAdvanceIncompleteSyncAnchor() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.markSynced(thread: "thread", timestamp: 50)
        try db.upsert([message("live", timestamp: 200)])
        #expect(try db.anchors()["thread"] == 50)
        try db.markSynced(thread: "thread", timestamp: 200)
        try db.markSynced(thread: "thread", timestamp: 100)
        #expect(try db.anchors()["thread"] == 200)
    }

    @Test func olderHistoryCannotReplaceTheLatestPreview() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert(Conversation(id: "thread", title: "Alex", preview: "Newest", updatedAt: 200))
        try db.upsert([message("old", timestamp: 50)])
        try db.upsert(Conversation(id: "thread", title: "Alex", preview: "Stale", updatedAt: 10))
        #expect(try db.conversations().first?.preview == "Newest")
    }

    @Test func deletionClearsOnlyTheTargetConversation() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert([message("one")])
        try db.upsert(Conversation(id: "other", title: "Other"))
        try db.saveDraft("Draft", thread: "thread"); try db.markSynced(thread: "thread", timestamp: 100)
        try db.deleteConversation(id: "thread")
        #expect(try db.messages(in: "thread").isEmpty)
        #expect(try db.draft(for: "thread").isEmpty)
        #expect(try db.anchors()["thread"] == nil)
        #expect(try db.conversations().map(\.id) == ["other"])
    }

    @Test func accountFilesRemainIndependent() throws {
        let (first, firstURL) = try database(), (second, secondURL) = try database()
        defer { try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent()); try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent()) }
        try first.upsert([message("private")])
        #expect(try second.messages(in: "thread").isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: firstURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func unreadBadgeCountsMessagesOnceAndSurvivesReadSnapshots() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let snapshot = Conversation(id: "thread", title: "Alex", updatedAt: 300, unread: true, readAt: 100)
        try db.upsert(snapshot)
        var first = message("first", timestamp: 200); first.isOwn = false
        var second = message("second", timestamp: 300); second.isOwn = false
        var old = message("old", timestamp: 50); old.isOwn = false
        try db.upsert([first, second, old, message("own", timestamp: 250)])
        try db.upsert([first, second])
        #expect(try db.unreadMessageCount() == 2)
        try db.markViewed("thread")
        try db.upsert(snapshot) // A stale server snapshot cannot undo reading on this Mac.
        #expect(try db.unreadMessageCount() == 0)
        let reopened = try MessageDatabase(url: url)
        try reopened.upsert(snapshot)
        #expect(try reopened.unreadMessageCount() == 0)
        var third = message("third", timestamp: 400); third.isOwn = false
        try reopened.upsert([third])
        #expect(try reopened.unreadMessageCount() == 1)
        try reopened.upsert(Conversation(id: "thread", title: "Alex", updatedAt: 400, unread: false, readAt: 400))
        #expect(try reopened.unreadMessageCount() == 0)
    }

    @Test func unreadBadgeIgnoresEmptyThreadsAndReadHistory() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert(Conversation(id: "unloaded", title: "Unread", updatedAt: 200, unread: true))
        try db.upsert(Conversation(id: "thread", title: "Read", updatedAt: 100, unread: false, readAt: 100))
        var old = message("old", timestamp: 100); old.isOwn = false
        try db.upsert([old])
        #expect(try db.unreadMessageCount() == 0)
        try db.deleteConversation(id: "unloaded")
        #expect(try db.unreadMessageCount() == 0)
    }

    @Test func badgeKeepsOldUnreadMessagesAndClearsAfterReceiptOrDeletion() throws {
        let (db, url) = try database(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try db.upsert(Conversation(id: "thread", title: "History", updatedAt: 100, unread: true))
        var first = message("old", timestamp: 100); first.isOwn = false
        var second = message("new", timestamp: 200); second.isOwn = false
        try db.upsert([first, second])
        #expect(try db.unreadMessageCount() == 2)
        try db.markRead("thread", through: 100)
        #expect(try db.unreadMessageCount() == 1)
        try db.markRead("thread", through: 50)
        #expect(try db.unreadMessageCount() == 1)
        try db.deleteMessage(id: "new")
        #expect(try db.unreadMessageCount() == 0)
        try db.upsert([second])
        #expect(try db.unreadMessageCount() == 1)
        try db.markRead("thread", through: 200)
        #expect(try db.unreadMessageCount() == 0)
        let reopened = try MessageDatabase(url: url)
        #expect(try reopened.unreadMessageCount() == 0)
    }
}
