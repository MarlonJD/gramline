import AVKit
import DMCore
import SwiftUI

struct DirectMediaViewer: View {
    let message: Message
    let service: SharedPostService
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var retry = 0
    @State private var file: URL?
    @State private var player: AVPlayer?
    @State private var error: String?
    private var media: DirectMedia? { message.directMedia }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(media?.label ?? "Media").font(.headline)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.help("Close").keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            ZStack {
                Color.black.opacity(0.92)
                if let restriction = media?.restriction {
                    Text(restriction).foregroundStyle(.white).padding()
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center).frame(maxWidth: 430)
                        Button("Try Again") { retry += 1 }
                    }.foregroundStyle(.white).padding()
                } else if let player {
                    NativeVideoPlayer(player: player)
                        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: player.currentItem)) { _ in
                            stopPlayback(); error = "This video could not be played. Try again or open it in Instagram."
                        }
                } else if let file { LocalMediaImage(url: file).padding(12) }
                else { ProgressView("Loading…").tint(.white).foregroundStyle(.white) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let media, media.items.count > 1 {
                HStack(spacing: 20) {
                    Button { index -= 1 } label: { Label("Previous", systemImage: "chevron.left") }
                        .disabled(index == 0).keyboardShortcut(.leftArrow, modifiers: [])
                    Text("\(index + 1) / \(media.items.count)").monospacedDigit()
                    Button { index += 1 } label: { Label("Next", systemImage: "chevron.right") }
                        .disabled(index == media.items.count - 1).keyboardShortcut(.rightArrow, modifiers: [])
                }.padding(12)
            }
        }
        .frame(width: 720, height: 690)
        .task(id: "\(message.id):\(index):\(retry)") {
            stopPlayback(); file = nil; error = nil
            guard media?.isRestricted == false else { return }
            do {
                let (local, kind) = try await service.media(for: message, index: index, refresh: retry > 0)
                try Task.checkCancellation()
                if kind == "video" {
                    let asset = AVURLAsset(url: local)
                    guard try await asset.load(.isPlayable) else { throw CoreError(code: "media_format", message: "This video format cannot be played. Open it in Instagram.") }
                    try Task.checkCancellation()
                    let loaded = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                    player = loaded; service.play(loaded)
                } else { file = local }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
        .onDisappear { stopPlayback() }
    }

    private func stopPlayback() { player?.pause(); player?.replaceCurrentItem(with: nil); player = nil }
}
