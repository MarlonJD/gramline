import DMCore
import Foundation
import Testing

struct AppearanceTests {
    @Test @MainActor func themeSurvivesMailboxSnapshotsAndExplicitDefaultClearsIt() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "instadm-appearance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
        let theme = try JSONDecoder().decode(ChatTheme.self, from: Data(#"{"normal":{"outgoingColors":["FF123456"],"backgroundColor":"FFFFFFFF"},"dark":{"outgoingColors":["FF654321"],"backgroundColor":"FF000000"}}"#.utf8))
        var detail = Conversation(id: "thread", title: "Themed", updatedAt: 100, avatarURL: "https://s.fbcdn.net/profile.jpg")
        detail.theme = theme; detail.themeLoaded = true
        try db.upsert(detail)
        try db.upsert(Conversation(id: "thread", title: "Themed", updatedAt: 200, avatarURL: detail.avatarURL))
        let reopened = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
        let saved = try reopened.conversations().first
        #expect(saved?.theme == theme)
        #expect(saved?.avatarURL == detail.avatarURL)
        #expect(saved?.theme?.palette(darkMode: true)?.backgroundColor == "FF000000")
        #expect(saved?.theme?.palette(darkMode: false)?.backgroundColor == "FFFFFFFF")
        detail.theme = nil
        try reopened.upsert(detail)
        #expect(try reopened.conversations().first?.theme == nil)
        #expect(try reopened.conversations().first?.updatedAt == 200)
    }
}
