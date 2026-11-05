import AppKit
import ImageIO
import SwiftUI

struct LocalMediaImage: View {
    let url: URL
    var maximumPixels = 1800
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Label("Image unavailable", systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
        }
        .task(id: url) {
            image = nil
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maximumPixels]
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                image = NSImage(cgImage: thumbnail, size: .zero)
            }
        }
    }
}
