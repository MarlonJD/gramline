import AVKit
import DMCore
import SwiftUI

struct SharedPostViewer: View {
    let post: SharedPost
    let service: SharedPostService
    @Environment(\.dismiss) private var dismiss
    @State private var content: SharedPostContent?
    @State private var index = 0
    @State private var file: URL?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var isLoading = true
    @State private var retry = 0

    private var item: SharedMediaItem? {
        guard let content, content.items.indices.contains(index) else { return nil }
        return content.items[index]
    }
    private var author: String { content?.author.isEmpty == false ? content!.author : post.author }
    private var caption: String { content?.caption.isEmpty == false ? content!.caption : post.caption }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(author.isEmpty ? "Instagram \(post.label)" : author).font(.headline)
                    Text(post.label).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = post.instagramURL { Link(destination: url) { Label("Open in Instagram", systemImage: "arrow.up.right.square") } }
                Button { dismiss() } label: { Image(systemName: "xmark") }.help("Close").keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ZStack {
                Color.black.opacity(0.92)
                if let error {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(error).multilineTextAlignment(.center).frame(maxWidth: 430)
                        Button("Try Again") { retry += 1 }
                    }.foregroundStyle(.white).padding()
                } else if isLoading {
                    ProgressView("Loading \(post.label.lowercased())…").tint(.white).foregroundStyle(.white)
                } else if let player {
                    NativeVideoPlayer(player: player)
                        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: player.currentItem)) { _ in
                            stopPlayback(); error = "This video could not be played. Try again or open it in Instagram."
                        }
                } else if let file { LocalMediaImage(url: file).padding(12) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let content, content.items.count > 1 {
                HStack(spacing: 20) {
                    Button { index -= 1 } label: { Label("Previous", systemImage: "chevron.left") }
                        .disabled(index == 0).keyboardShortcut(.leftArrow, modifiers: [])
                    Text("\(index + 1) / \(content.items.count)").monospacedDigit().frame(minWidth: 55)
                    Button { index += 1 } label: { Label("Next", systemImage: "chevron.right") }
                        .disabled(index == content.items.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                }.padding(12)
            }
            if !caption.isEmpty {
                Divider()
                ScrollView { Text(caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(16) }
                    .frame(maxHeight: 100)
            }
        }
        .frame(width: 720, height: 690)
        .task(id: retry) {
            stopPlayback(); content = nil; file = nil; error = nil; isLoading = true
            do {
                let result = try await service.content(for: post, refresh: retry > 0)
                try Task.checkCancellation()
                guard !result.items.isEmpty else { throw CoreError(code: "media_unavailable", message: "This post has no available media.") }
                index = min(max(result.selectedIndex, 0), result.items.count - 1)
                content = result
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false }
            }
        }
        .task(id: item?.id) {
            stopPlayback(); file = nil
            guard let item else { return }
            error = nil; isLoading = true
            do {
                let (local, kind) = try await service.media(for: post, item: item)
                try Task.checkCancellation()
                if kind == "video" {
                    let asset = AVURLAsset(url: local)
                    guard try await asset.load(.isPlayable) else { throw CoreError(code: "media_format", message: "This video format cannot be played. Open it in Instagram.") }
                    try Task.checkCancellation()
                    let loaded = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player = loaded; service.play(loaded)
                } else { file = local }
                isLoading = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription; isLoading = false }
            }
        }
        .onDisappear { stopPlayback() }
    }

    private func stopPlayback() { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
}
