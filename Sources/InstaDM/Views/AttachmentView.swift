import AppKit
import DMCore
import ImageIO
import SwiftUI

struct AttachmentView: View {
    let attachment: MessageAttachment
    var compact = false
    @State private var image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: compact ? 120 : 340, maxHeight: compact ? 80 : 280)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Label(attachment.filename, systemImage: attachment.isImage ? "photo" : "doc")
                    .lineLimit(2).frame(maxWidth: compact ? 160 : 300, alignment: .leading)
            }
            if image != nil { Text(attachment.filename).font(.caption).lineLimit(1) }
            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.byteCount), countStyle: .file))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .task(id: attachment.id) {
            guard attachment.isImage, let url = attachment.localURL else { return }
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: compact ? 240 : 680]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                image = NSImage(cgImage: thumbnail, size: .zero)
            }
        }
    }
}
