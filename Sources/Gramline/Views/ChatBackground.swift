import AppKit
import DMCore
import ImageIO
import SwiftUI

extension Color {
    init?(instagramARGB value: String?) {
        guard let value, value.count == 8, let bits = UInt32(value, radix: 16) else { return nil }
        self.init(.sRGB, red: Double((bits >> 16) & 255) / 255, green: Double((bits >> 8) & 255) / 255,
                  blue: Double(bits & 255) / 255, opacity: Double((bits >> 24) & 255) / 255)
    }
}

extension ThemePalette {
    var background: Color? { Color(instagramARGB: backgroundColor) }
    var incoming: Color? { Color(instagramARGB: incomingColor) }
    var incomingText: Color? { Color(instagramARGB: incomingTextColor) }
    var outgoing: [Color] { outgoingColors.compactMap { Color(instagramARGB: $0) } }
    var outgoingText: Color? { Color(instagramARGB: outgoingTextColor) }
    var navigation: Color? { Color(instagramARGB: navigationColor) }
    var navigationText: Color? { Color(instagramARGB: navigationTextColor) }
    var composer: Color? { Color(instagramARGB: composerColor) }
    var composerInput: Color? { Color(instagramARGB: composerInputColor) }
    var composerText: Color? { Color(instagramARGB: composerTextColor) }
    var chromeBackground: Color { navigation ?? background ?? Color(nsColor: .windowBackgroundColor) }
    var chromeText: Color { navigationText ?? incomingText ?? .primary }
    var chromeSelection: Color { outgoing.first ?? incoming ?? .accentColor }
    var chromeColorScheme: ColorScheme? {
        guard let value = navigationColor ?? backgroundColor, let bits = UInt32(value, radix: 16) else { return nil }
        let brightness = 0.2126 * Double((bits >> 16) & 255) + 0.7152 * Double((bits >> 8) & 255) + 0.0722 * Double(bits & 255)
        return brightness < 128 ? .dark : .light
    }
}

struct ChatBackground: View {
    let palette: ThemePalette?
    let cache: SharedMediaCache?
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                palette?.background ?? .clear
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
        .task(id: palette?.backgroundURL) {
            image = nil
            guard let cache, let address = palette?.backgroundURL, let remote = URL(string: address) else { return }
            do {
                let file = try await cache.file(for: remote, kind: .image)
                try Task.checkCancellation()
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2048]
                if let source = CGImageSourceCreateWithURL(file as CFURL, nil), let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                    image = NSImage(cgImage: thumbnail, size: .zero)
                }
            } catch { /* The server's background color remains while its image is unavailable. */ }
        }
    }
}
