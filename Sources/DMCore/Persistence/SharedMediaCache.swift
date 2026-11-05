import CryptoKit
import Foundation

/// Disposable media only. Message identity and captions remain in SQLite.
public actor SharedMediaCache {
    public enum MediaKind: String, Sendable { case image, video }
    public typealias Download = @Sendable (URL, Int64, MediaKind) async throws -> URL
    private let directory: URL
    private let byteLimit: Int64
    private let lifetime: TimeInterval
    private let download: Download
    private var pending: [String: Task<URL, Error>] = [:]
    private let slots = MediaDownloadSlots()

    public init(directory: URL, byteLimit: Int64 = 512_000_000, lifetime: TimeInterval = 86_400, download: @escaping Download = SharedMediaCache.download) {
        self.directory = directory; self.byteLimit = byteLimit; self.lifetime = lifetime; self.download = download
    }

    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["cdninstagram.com", "fbcdn.net", "instagram.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func file(for remote: URL, kind: MediaKind) async throws -> URL {
        guard Self.isAllowed(remote) else { throw CoreError(code: "media_url", message: "Instagram returned an unsupported media address.") }
        try Task.checkCancellation()
        let key = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined() + (kind == .video ? ".mp4" : ".image")
        let destination = directory.appendingPathComponent(key)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try prune(reserving: 0)
        if manager.fileExists(atPath: destination.path) {
            try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: destination.path)
            return destination
        }
        if let task = pending[key] { return try await task.value }
        let limit = min(byteLimit, kind == .video ? 128_000_000 : 20_000_000)
        let download = self.download
        let task = Task {
            await slots.acquire()
            defer { Task { await slots.release() } }
            try Task.checkCancellation()
            let temporary = try await download(remote, limit, kind)
            defer { try? manager.removeItem(at: temporary) }
            try Task.checkCancellation()
            let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= limit else { throw CoreError(code: "media_size", message: "This media is larger than the in-app viewing limit. Open it in Instagram.") }
            try self.prune(reserving: Int64(size))
            try manager.moveItem(at: temporary, to: destination)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return destination
        }
        pending[key] = task
        defer { pending[key] = nil }
        return try await task.value
    }

    public func clear() {
        for task in pending.values { task.cancel() }
        pending.removeAll()
        try? FileManager.default.removeItem(at: directory)
    }

    private func prune(reserving bytes: Int64) throws {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .creationDateKey, .isRegularFileKey]
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        var retained: [(URL, Int64, Date)] = []
        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isRegularFile == true else { continue }
            if Date().timeIntervalSince(values.creationDate ?? .distantPast) > lifetime { try manager.removeItem(at: file) }
            else { retained.append((file, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)) }
        }
        var total = retained.reduce(Int64(0)) { $0 + $1.1 }
        for (file, size, _) in retained.sorted(by: { $0.2 < $1.2 }) where total + bytes > byteLimit {
            try manager.removeItem(at: file); total -= size
        }
    }

    public static func download(_ url: URL, limit: Int64, kind: MediaKind) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            let (temporary, response) = try await session.download(for: URLRequest(url: url), delegate: MediaDownloadGuard(limit: limit))
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw CoreError(code: "media_expired", message: "The media link expired or is unavailable. Try loading the post again.")
            }
            guard let mime = response.mimeType, mime.hasPrefix(kind == .image ? "image/" : "video/") || (kind == .video && mime == "application/octet-stream") else {
                try? FileManager.default.removeItem(at: temporary)
                throw CoreError(code: "media_format", message: "This media format cannot be displayed. Open it in Instagram.")
            }
            return temporary
        } catch is CancellationError { throw CancellationError() }
        catch let error as CoreError { throw error }
        catch {
            try Task.checkCancellation()
            throw CoreError(code: "media_download", message: "The media could not be downloaded within the size or connection limits. Try again or open it in Instagram.")
        }
    }
}

private actor MediaDownloadSlots {
    private var available = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if available > 0 { available -= 1 }
        else { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().resume() }
    }
}

private final class MediaDownloadGuard: NSObject, URLSessionDownloadDelegate {
    let limit: Int64
    init(limit: Int64) { self.limit = limit }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(request.url.map(SharedMediaCache.isAllowed) == true ? request : nil)
    }
}
