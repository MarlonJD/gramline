import AppKit
import UniformTypeIdentifiers

enum AttachmentPasteboard {
    enum Content: Sendable {
        case file(URL)
        case image(Data, UTType)
    }

    @MainActor static func canRead(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) || pasteboard.availableType(from: [.png, .tiff, .init(UTType.jpeg.identifier), .init(UTType.gif.identifier), .init(UTType.webP.identifier), .init(UTType.heic.identifier)]) != nil
    }

    /// Called only for an explicit Paste action. File URLs take precedence over Finder icons.
    @MainActor static func read(_ pasteboard: NSPasteboard = .general) -> [Content] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return urls.map(Content.file)
        }
        for type: UTType in [.png, .jpeg, .gif, .webP, .tiff, .heic] {
            if let data = pasteboard.data(forType: .init(type.identifier)) { return [.image(data, type)] }
        }
        return []
    }
}
