import DMCore
import SwiftUI

struct SharedPostCard: View {
    let post: SharedPost
    let service: SharedPostService
    let open: () -> Void
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.quaternary)
                    if let preview {
                        LocalMediaImage(url: preview, maximumPixels: 720)
                    } else {
                        Image(systemName: post.kind == "reel" ? "film" : "photo.on.rectangle")
                            .font(.largeTitle).foregroundStyle(.secondary)
                    }
                    if post.kind == "reel" {
                        Image(systemName: "play.circle.fill").font(.system(size: 44))
                            .symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.55))
                    }
                }
                .frame(width: 300, height: post.kind == "reel" ? 300 : 220)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }.buttonStyle(.plain).help(post.kind == "reel" ? "Play reel" : "View post")
                .accessibilityLabel(post.kind == "reel" ? "Play shared reel" : "View shared post")
            HStack {
                Text(post.author.isEmpty ? "Instagram" : post.author).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Label(post.label, systemImage: post.kind == "reel" ? "play.rectangle" : "photo").font(.caption).foregroundStyle(.secondary)
            }
            if !post.title.isEmpty && post.title != post.author { Text(post.title).font(.callout).lineLimit(2) }
            if !post.caption.isEmpty { Text(post.caption).font(.callout).lineLimit(3).foregroundStyle(.secondary) }
            if let url = post.instagramURL { Link("Open in Instagram", destination: url).font(.caption) }
        }
        .frame(width: 300, alignment: .leading)
        .task(id: post.previewURL + post.url) {
            preview = nil
            do {
                let file = try await service.preview(for: post)
                try Task.checkCancellation(); preview = file
            } catch { /* The card remains actionable when its thumbnail is unavailable. */ }
        }
    }
}
