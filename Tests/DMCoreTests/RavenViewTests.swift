import DMCore
import Foundation
import Testing

struct RavenViewTests {
    @Test @MainActor func ambiguousOpenSurvivesRestartAndRequiresServerAdvance() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "raven-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "history.sqlite")
        let db = try MessageDatabase(url: url)
        try db.reserveRavenView(thread: "t", message: "m", seenCount: 0)
        let reopened = try MessageDatabase(url: url)
        #expect(throws: CoreError.self) { try reopened.reserveRavenView(thread: "t", message: "m", seenCount: 0) }
        // The server confirmed the first opening. An explicit replay can proceed.
        try reopened.reserveRavenView(thread: "t", message: "m", seenCount: 1)
        #expect(throws: CoreError.self) { try reopened.reserveRavenView(thread: "t", message: "m", seenCount: 1) }
        #expect(throws: CoreError.self) { try reopened.reserveRavenView(thread: "t", message: "m", seenCount: 2) }
    }

    @Test @MainActor func unsubmittedViewCanBeRetriedAndAccountsAreIsolated() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "raven-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try MessageDatabase(url: directory.appending(path: "one.sqlite"))
        try db.reserveRavenView(thread: "t", message: "m", seenCount: 0)
        try db.releaseUnsubmittedRavenView(thread: "t", message: "m", seenCount: 0)
        try db.reserveRavenView(thread: "t", message: "m", seenCount: 0)
        let other = try MessageDatabase(url: directory.appending(path: "two.sqlite"))
        try other.reserveRavenView(thread: "t", message: "m", seenCount: 0)
    }

    @Test @MainActor func historyRefreshDoesNotResetOpenedState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "raven-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try MessageDatabase(url: directory.appending(path: "history.sqlite"))
        var message = Message(id: "m", threadID: "t", text: "Photo", timestamp: 100)
        message.directMedia = try JSONDecoder().decode(DirectMedia.self, from: Data(#"{"kind":"image","viewMode":1,"items":[]}"#.utf8))
        try db.upsert([message])
        try db.setRavenState(thread: "t", message: "m", state: "replayed")
        try db.upsert([message])
        let saved = try db.messages(in: "t").first?.directMedia
        #expect(saved?.viewState == "replayed")
        #expect(saved?.canOpenRestricted == false)
        #expect(saved?.items.isEmpty == true)
    }
}
