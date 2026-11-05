import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns private copies so a copied file can move or disappear before sending.
public struct AttachmentStore: Sendable {
    public static let imageLimit = 8_000_000
    public static let fileLimit = 25_000_000
    public let directory: URL
    public init(directory: URL) { self.directory = directory }

    public func prepare(file url: URL) throws -> MessageAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw failure("Choose a file, not a folder.") }
        guard let size = values.fileSize, size > 0, size <= Self.fileLimit else { throw failure("Files must be nonempty and no larger than 25 MB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        return try prepare(data: data, filename: url.lastPathComponent, type: type)
    }

    public func prepare(data: Data, filename: String, type: UTType) throws -> MessageAttachment {
        guard !data.isEmpty, data.count <= Self.fileLimit else { throw failure("Files must be nonempty and no larger than 25 MB.") }
        var bytes = data, name = filename, mime = type.preferredMIMEType ?? "application/octet-stream"
        if type.conforms(to: .image) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { throw failure("This image could not be opened.") }
            let actualType = (CGImageSourceGetType(source) as String?).flatMap { UTType($0) }
            let supported: [UTType] = [.jpeg, .png, .gif, .webP]
            if let actualType, supported.contains(actualType) {
                mime = actualType.preferredMIMEType ?? mime
            } else {
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096]
                guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw failure("This image could not be converted.") }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { throw failure("This image could not be converted.") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw failure("This image could not be converted.") }
                bytes = output as Data; mime = "image/png"
                name = (filename as NSString).deletingPathExtension + ".png"
            }
            guard bytes.count <= Self.imageLimit else { throw failure("Photos must be no larger than 8 MB. Choose a smaller image.") }
        }
        let id = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appending(path: id)
        try bytes.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return MessageAttachment(id: id, filename: name, mimeType: mime, byteCount: bytes.count, localPath: file.path)
    }

    private func failure(_ message: String) -> CoreError { CoreError(code: "attachment", message: message) }
}
