import DMCore
import Foundation
import Testing

struct SharedMediaTests {
    @Test @MainActor func sharedPostIsPersistedAndHistoryEnrichesOldMessages() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "instadm-post-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
        var message = Message(id: "m1", threadID: "t1", text: "Attachment", timestamp: 100)
        try db.upsert([message])
        message.sharedPost = SharedPost(mediaID: "9007199254740993", shortcode: "ABC", url: "https://www.instagram.com/reel/ABC/", kind: "reel", caption: "A caption")
        message.kind = "shared_post"
        try db.upsert([message])
        let reopened = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
        let rows = try reopened.messages(in: "t1")
        #expect(rows.count == 1)
        #expect(rows.first?.sharedPost == message.sharedPost)
    }

    @Test func mediaAddressesCannotLeaveInstagramCDNs() {
        for raw in ["file:///tmp/file", "https://127.0.0.1/a", "https://fbcdn.net.evil.example/a", "https://user:secret@fbcdn.net/a", "http://s.cdninstagram.com/a", "https://s.fbcdn.net:8443/a"] {
            #expect(!SharedMediaCache.isAllowed(URL(string: raw)!))
        }
        #expect(SharedMediaCache.isAllowed(URL(string: "https://scontent.cdninstagram.com/a?oe=abc")!))
        #expect(SharedMediaCache.isAllowed(URL(string: "https://video.fbcdn.net/a")!))
    }

    @Test func cacheDeduplicatesAndEvictsWithinItsBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "instadm-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let downloads = DownloadCounter(root: root, bytes: 6)
        let cache = SharedMediaCache(directory: root.appending(path: "cache"), byteLimit: 10, download: { url, _, _ in try await downloads.file(url) })
        let remote = URL(string: "https://s.cdninstagram.com/a")!
        async let first = cache.file(for: remote, kind: .image)
        async let second = cache.file(for: remote, kind: .image)
        let (one, two) = try await (first, second)
        #expect(one == two)
        #expect(await downloads.count == 1)
        let other = try await cache.file(for: URL(string: "https://s.cdninstagram.com/b")!, kind: .image)
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(!FileManager.default.fileExists(atPath: one.path))
        let permissions = try FileManager.default.attributesOfItem(atPath: other.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
        await cache.clear()
        #expect(!FileManager.default.fileExists(atPath: other.path))
    }

    @Test func oversizedAndExpiredCacheEntriesAreNotRetained() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "instadm-cache-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let downloads = DownloadCounter(root: root, bytes: 12)
        let remote = URL(string: "https://s.cdninstagram.com/a")!
        let small = SharedMediaCache(directory: root.appending(path: "small"), byteLimit: 10, download: { url, _, _ in try await downloads.file(url) })
        do { _ = try await small.file(for: remote, kind: .image); Issue.record("Oversized download was accepted") }
        catch { #expect((error as? CoreError)?.code == "media_size") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "small").path).isEmpty)
        let expiring = SharedMediaCache(directory: root.appending(path: "expired"), lifetime: -1, download: { url, _, _ in try await downloads.file(url) })
        _ = try await expiring.file(for: remote, kind: .image)
        _ = try await expiring.file(for: remote, kind: .image)
        #expect(await downloads.count == 3)
    }
}

private actor DownloadCounter {
    let root: URL
    let bytes: Int
    var count = 0
    init(root: URL, bytes: Int) { self.root = root; self.bytes = bytes }
    func file(_ remote: URL) async throws -> URL {
        count += 1
        try await Task.sleep(for: .milliseconds(20))
        let file = root.appending(path: UUID().uuidString)
        try Data(repeating: 1, count: bytes).write(to: file)
        return file
    }
}
