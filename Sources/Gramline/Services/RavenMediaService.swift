import DMCore
import Foundation

@MainActor
final class RavenMediaService {
    struct Prepared {
        let grant: RavenPreparation
        let file: URL
        let message: Message
    }
    typealias Request = @MainActor (String, JSONValue) async throws -> JSONValue
    private let request: Request
    private let database: MessageDatabase
    private let directory: URL
    private let changed: @MainActor () -> Void
    private var closed = false
    private var activeFile: URL?

    init(directory: URL, database: MessageDatabase, changed: @escaping @MainActor () -> Void, request: @escaping Request) {
        self.directory = directory; self.database = database; self.request = request; self.changed = changed
        // Recover after an interrupted view; content is never retained to replay.
        try? FileManager.default.removeItem(at: directory)
    }

    func prepare(_ message: Message) async throws -> Prepared {
        guard !closed, !message.isOwn else { throw CancellationError() }
        let response: JSONValue
        do { response = try await request("raven_prepare", .object(["threadID": .string(message.threadID), "messageID": .string(message.id)])) }
        catch {
            if (error as? CoreError)?.code == "raven_unavailable" {
                try database.setRavenState(thread: message.threadID, message: message.id, state: "unavailable"); changed()
            }
            throw error
        }
        let grant = try response.decode(RavenPreparation.self)
        try Task.checkCancellation()
        guard !closed, SharedMediaCache.isAllowed(grant.url), ["once", "replayable"].contains(grant.viewMode), ["image", "video"].contains(grant.kind) else {
            throw CoreError(code: "raven_response", message: "Instagram returned an unsupported media response.")
        }
        let temporary = try await SharedMediaCache.download(grant.url, limit: grant.kind == "video" ? 80_000_000 : 20_000_000,
                                                           kind: grant.kind == "video" ? .video : .image)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= (grant.kind == "video" ? 80_000_000 : 20_000_000) else {
            throw CoreError(code: "media_size", message: "This media is too large to open here.")
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: UUID().uuidString + (grant.kind == "video" ? ".mp4" : ".image"))
        try FileManager.default.moveItem(at: temporary, to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        if let activeFile { try? FileManager.default.removeItem(at: activeFile) }
        activeFile = file
        return Prepared(grant: grant, file: file, message: message)
    }

    func consume(_ prepared: Prepared, replay: RavenOpenResult? = nil) async throws -> RavenOpenResult {
        try Task.checkCancellation()
        guard !closed, activeFile == prepared.file else { throw CancellationError() }
        let message = prepared.message, seen = replay?.seenCount ?? prepared.grant.seenCount
        try database.reserveRavenView(thread: message.threadID, message: message.id, seenCount: seen)
        do {
            let response = try await request("raven_open", .object(["token": .string(replay?.replayToken ?? prepared.grant.token)]))
            try Task.checkCancellation()
            guard !closed, activeFile == prepared.file else { throw CancellationError() }
            let result = try response.decode(RavenOpenResult.self)
            guard result.seenCount == seen + 1 else { throw CoreError(code: "raven_unknown", message: "Instagram did not confirm the viewing status.") }
            try database.setRavenState(thread: message.threadID, message: message.id, state: result.seenCount == 2 ? "replayed" : "opened")
            changed()
            return result
        } catch {
            if (error as? CoreError)?.code == "raven_not_opened" {
                try database.releaseUnsubmittedRavenView(thread: message.threadID, message: message.id, seenCount: seen)
            }
            throw error
        }
    }

    func discard(_ prepared: Prepared) {
        try? FileManager.default.removeItem(at: prepared.file)
        if activeFile == prepared.file { activeFile = nil }
    }
    func close() {
        closed = true; activeFile = nil
        try? FileManager.default.removeItem(at: directory)
    }
}
