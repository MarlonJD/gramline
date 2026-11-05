import AVKit
import DMCore
import Foundation

@MainActor
final class SharedPostService {
    typealias Resolve = @MainActor (SharedPost) async throws -> SharedPostContent
    typealias ResolveMessage = @MainActor (Message) async throws -> DirectMedia
    private let cache: SharedMediaCache
    private let resolve: Resolve
    private let resolveMessage: ResolveMessage
    private var results: [String: (Date, SharedPostContent)] = [:]
    private var requests: [String: Task<SharedPostContent, Error>] = [:]
    private weak var activePlayer: AVPlayer?

    init(directory: URL, resolve: @escaping Resolve, resolveMessage: @escaping ResolveMessage) {
        cache = SharedMediaCache(directory: directory); self.resolve = resolve; self.resolveMessage = resolveMessage
    }

    func content(for post: SharedPost, refresh: Bool = false) async throws -> SharedPostContent {
        let key = post.url
        if !refresh, let (date, content) = results[key], Date().timeIntervalSince(date) < 300 { return content }
        if let request = requests[key] { return try await request.value }
        let request = Task { try await resolve(post) }
        requests[key] = request
        defer { requests[key] = nil }
        let content = try await request.value
        try Task.checkCancellation()
        if results.count >= 100 { results.removeAll() }
        results[key] = (Date(), content)
        return content
    }

    func preview(for post: SharedPost) async throws -> URL {
        if let remote = URL(string: post.previewURL), SharedMediaCache.isAllowed(remote) {
            do { return try await cache.file(for: remote, kind: .image) }
            catch { try Task.checkCancellation() }
        }
        let content = try await content(for: post)
        guard !content.items.isEmpty else { throw unavailable() }
        let item = content.items[min(max(content.selectedIndex, 0), content.items.count - 1)]
        guard let remote = URL(string: item.previewURL.isEmpty && item.kind == "image" ? item.url : item.previewURL) else { throw unavailable() }
        return try await cache.file(for: remote, kind: .image)
    }

    func media(for post: SharedPost, item: SharedMediaItem) async throws -> (URL, String) {
        do { return (try await download(item), item.kind) }
        catch {
            try Task.checkCancellation()
            // A CDN token can expire while the message stays in history. Resolve
            // once from stable identity; never retry a send or loop indefinitely.
            guard (error as? CoreError)?.code == "media_expired" else { throw error }
            let updated = try await content(for: post, refresh: true)
            guard let replacement = updated.items.first(where: { $0.id == item.id }) else { throw unavailable() }
            return (try await download(replacement), replacement.kind)
        }
    }

    private func download(_ item: SharedMediaItem) async throws -> URL {
        guard let remote = URL(string: item.url), !item.url.isEmpty else { throw unavailable() }
        return try await cache.file(for: remote, kind: item.kind == "video" ? .video : .image)
    }

    func preview(for media: DirectMedia) async throws -> URL {
        guard !media.isRestricted, let item = media.items.first else { throw unavailable() }
        let address = item.previewURL.isEmpty && item.kind == "image" ? item.url : item.previewURL
        guard !address.isEmpty, let remote = URL(string: address) else { throw unavailable() }
        return try await cache.file(for: remote, kind: .image)
    }

    func media(for message: Message, index: Int, refresh: Bool) async throws -> (URL, String) {
        guard let media = message.directMedia, !media.isRestricted else { throw unavailable() }
        var current = refresh ? try await resolveMessage(message) : media
        guard !current.isRestricted, current.items.indices.contains(index) else { throw unavailable() }
        let item = current.items[index]
        do { return (try await download(item), item.kind) }
        catch {
            try Task.checkCancellation()
            guard !refresh, (error as? CoreError)?.code == "media_expired" else { throw error }
            current = try await resolveMessage(message)
            guard !current.isRestricted, let replacement = current.items.first(where: { $0.id == item.id }) else { throw unavailable() }
            return (try await download(replacement), replacement.kind)
        }
    }

    func play(_ player: AVPlayer) {
        activePlayer?.pause(); activePlayer = player; player.play()
    }
    func stopPlayback() { activePlayer?.pause(); activePlayer = nil }
    func close() {
        stopPlayback()
        requests.values.forEach { $0.cancel() }; requests.removeAll(); results.removeAll()
        Task { await cache.clear() }
    }
    private func unavailable() -> CoreError { CoreError(code: "media_unavailable", message: "This media is unavailable. Open the post in Instagram.") }
}
