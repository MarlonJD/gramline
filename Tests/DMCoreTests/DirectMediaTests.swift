import DMCore
import Foundation
import Testing

struct DirectMediaTests {
    @Test @MainActor func photoEnrichmentAndRestrictedModesPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "instadm-direct-media-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let db = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
        var message = Message(id: "m", threadID: "thread", text: "Attachment", timestamp: 100)
        try db.upsert([message])
        for mode in [0, 1, 2, 99] {
            message.directMedia = try JSONDecoder().decode(DirectMedia.self, from: Data("{\"kind\":\"image\",\"viewMode\":\(mode),\"items\":[]}".utf8))
            try db.upsert([message])
            let reopened = try MessageDatabase(url: directory.appending(path: "messages.sqlite"))
            let media = try reopened.messages(in: "thread").first?.directMedia
            #expect(media?.isRestricted == (mode != 2))
            #expect((media?.restriction != nil) == (mode != 2))
        }
        let plain = try JSONDecoder().decode(DirectMedia.self, from: Data(#"{"kind":"video","items":[{"id":"one","kind":"video","url":"https://s.fbcdn.net/video.mp4","previewURL":"","width":640,"height":480}]}"#.utf8))
        #expect(!plain.isRestricted)
        #expect(plain.label == "Video")
        #expect(plain.items.count == 1)
    }
}
