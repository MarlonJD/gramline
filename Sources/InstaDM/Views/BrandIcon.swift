import AppKit
import SwiftUI

struct BrandIcon: View {
    private static let image = Bundle.main.url(forResource: "InstaDM", withExtension: "png").flatMap { NSImage(contentsOf: $0) }
    var body: some View {
        if let image = Self.image { Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("InstaDM") }
    }
}
