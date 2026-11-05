import DMCore
import Foundation
import Testing
import UniformTypeIdentifiers

@MainActor struct AttachmentTests {
    @Test func copiedFilesAndDraftsSurviveOriginalRemovalAndRestart() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "instadm-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appending(path: "report.pdf"), bytes = Data("%PDF-1.4 test".utf8)
        try bytes.write(to: original)
        let attachment = try AttachmentStore(directory: root.appending(path: "Attachments")).prepare(file: original)
        try FileManager.default.removeItem(at: original)
        #expect(try Data(contentsOf: #require(attachment.localURL)) == bytes)
        let databaseURL = root.appending(path: "messages.sqlite")
        let db = try MessageDatabase(url: databaseURL)
        try db.saveDraftAttachments([attachment], thread: "thread")
        let reopened = try MessageDatabase(url: databaseURL)
        #expect(try reopened.draftAttachments(for: "thread") == [attachment])
        #expect(try reopened.referencesAttachment(attachment.id))
        try reopened.saveDraftAttachments([], thread: "thread")
        #expect(try !reopened.referencesAttachment(attachment.id))
        let attributes = try FileManager.default.attributesOfItem(atPath: #require(attachment.localPath))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func attachmentSurvivesEchoBeforeResponseAndHistory() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "instadm-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let db = try MessageDatabase(url: root.appending(path: "messages.sqlite"))
        let attachment = MessageAttachment(id: "photo", filename: "Photo.png", mimeType: "image/png", byteCount: 30, localPath: "/private/local/photo")
        let pending = Message(id: "local:123", threadID: "thread", clientID: "123", text: "Photo.png", timestamp: 100, isOwn: true, status: .sending, kind: "image", attachment: attachment)
        try db.upsert([pending])
        let echo = Message(id: "server", threadID: "thread", clientID: "123", text: "Photo", timestamp: 101, isOwn: true, kind: "attachment")
        try db.upsert([echo, echo])
        var response = echo; response.attachment = MessageAttachment(id: "photo", filename: "Photo.png", mimeType: "image/png", byteCount: 30)
        try db.upsert([response, echo])
        let messages = try db.messages(in: "thread")
        #expect(messages.count == 1)
        #expect(messages.first?.attachment == attachment)
        #expect(messages.first?.status == .sent)
        #expect(try db.referencesAttachment(attachment.id))
    }

    @Test func invalidAndOversizeAttachmentsAreRejected() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "instadm-media-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(directory: root)
        #expect(throws: CoreError.self) { try store.prepare(data: Data(), filename: "empty.txt", type: .plainText) }
        #expect(throws: CoreError.self) { try store.prepare(data: Data("not an image".utf8), filename: "bad.png", type: .png) }
        #expect(throws: CoreError.self) { try store.prepare(data: Data(repeating: 0, count: AttachmentStore.fileLimit + 1), filename: "large.bin", type: .data) }
    }
}
