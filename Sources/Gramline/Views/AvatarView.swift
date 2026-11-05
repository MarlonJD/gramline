import AppKit
import DMCore
import ImageIO
import SwiftUI

struct AvatarView: View {
    let name: String
    let url: String?
    let cache: SharedMediaCache?
    var size: CGFloat = 36
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Circle().fill(.tint.opacity(0.12))
            if let image { Image(nsImage: image).resizable().scaledToFill() }
            else { Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.44, weight: .semibold)).foregroundStyle(.tint) }
        }
        .frame(width: size, height: size).clipShape(Circle()).accessibilityHidden(true)
        .task(id: url) {
            image = nil
            guard let cache, let url, let remote = URL(string: url) else { return }
            do {
                let file = try await cache.file(for: remote, kind: .image)
                try Task.checkCancellation()
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 192]
                if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    image = NSImage(cgImage: thumbnail, size: .zero)
                }
            } catch { /* Initials remain visible when a profile image is unavailable. */ }
        }
    }
}
