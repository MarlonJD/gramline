import DMCore
import SwiftUI

struct DirectMediaCard: View {
    let media: DirectMedia
    let service: SharedPostService
    let isOwn: Bool
    let open: () -> Void
    @State private var preview: URL?

    var body: some View {
        if let restriction = media.restriction {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(isOwn ? "Disappearing" : (media.canOpenRestricted ? "View" : "Viewed")) \(media.label.lowercased())", systemImage: media.canOpenRestricted ? (media.kind == "video" ? "play.fill" : "eye") : "eye.slash")
                        .fontWeight(.semibold)
                    Text(restriction).font(.caption).opacity(0.7)
                }.frame(maxWidth: 260, alignment: .leading)
            }.buttonStyle(.plain).disabled(isOwn || !media.canOpenRestricted)
                .accessibilityLabel("\(media.label), \(restriction)")
        } else {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                        if let preview { LocalMediaImage(url: preview, maximumPixels: 720) }
                        else { Image(systemName: "photo").font(.largeTitle).opacity(0.6) }
                        if media.kind == "video" {
                            Image(systemName: "play.circle.fill").font(.system(size: 44))
                                .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                        }
                    }
                    .frame(width: 260, height: 220).clipShape(RoundedRectangle(cornerRadius: 10))
                    HStack {
                        Text("View \(media.label.lowercased())").font(.callout).fontWeight(.medium)
                        if media.items.count > 1 { Text("· \(media.items.count)").font(.caption) }
                    }
                }
            }.buttonStyle(.plain).accessibilityLabel("View \(media.label.lowercased())")
            .task(id: (media.items.first?.url ?? "") + (media.items.first?.previewURL ?? "")) {
                preview = nil
                do { let file = try await service.preview(for: media); try Task.checkCancellation(); preview = file }
                catch { /* Opening the card can refresh an expired media address. */ }
            }
        }
    }
}
