import AVKit
import DMCore
import SwiftUI

struct RavenMediaViewer: View {
    let message: Message
    let service: RavenMediaService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var prepared: RavenMediaService.Prepared?
    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var remaining = 0
    @State private var started = false
    @State private var replay: RavenOpenResult?
    @State private var awaitingReplay = false
    @State private var pass = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(message.directMedia?.viewMode == 0 ? "View once" : "Replay allowed", systemImage: "eye")
                Spacer()
                if started { Text("\(remaining)s").monospacedDigit().foregroundStyle(.secondary) }
                Button { dismiss() } label: { Image(systemName: "xmark") }.help("Close").keyboardShortcut(.cancelAction)
            }.padding(16)
            ZStack {
                Color.black
                if let error {
                    VStack(spacing: 16) {
                        Image(systemName: "eye.slash").font(.largeTitle)
                        Text(error).multilineTextAlignment(.center).frame(maxWidth: 440)
                        Button("Close") { dismiss() }
                    }.foregroundStyle(.white).padding()
                } else if awaitingReplay {
                    VStack(spacing: 16) {
                        Image(systemName: "arrow.counterclockwise").font(.largeTitle)
                        Text("You can view this once more.")
                        Button("Replay once") { awaitingReplay = false; pass += 1 }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        Text("Closing this window ends replay access.").font(.caption).foregroundStyle(.secondary)
                    }.foregroundStyle(.white)
                } else if let image {
                    Image(nsImage: image).resizable().scaledToFit().padding(12).accessibilityLabel("Disappearing photo")
                } else if let player {
                    NativeVideoPlayer(player: player, restricted: true)
                        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem)) { _ in remaining = 0 }
                        .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: player.currentItem)) { _ in dismiss() }
                } else { ProgressView("Opening…").tint(.white).foregroundStyle(.white) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("Disappears when closed. This viewing is reported to Instagram.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .frame(width: 640, height: 740)
        .task(id: pass) {
            do {
                let previous = pass == 0 ? nil : replay
                let loaded: RavenMediaService.Prepared
                if let prepared { loaded = prepared } else { loaded = try await service.prepare(message) }
                prepared = loaded
                // Decode before consuming so an unreadable file doesn't spend a view.
                let decoded = loaded.grant.kind == "image" ? NSImage(contentsOf: loaded.file) : nil
                var video: AVPlayer?
                if loaded.grant.kind == "video" {
                    let asset = AVURLAsset(url: loaded.file)
                    guard try await asset.load(.isPlayable) else { throw CoreError(code: "media_format", message: "This video cannot be played here.") }
                    video = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                } else if decoded == nil { throw CoreError(code: "media_format", message: "This photo cannot be displayed here.") }
                try Task.checkCancellation()
                let result = try await service.consume(loaded, replay: previous)
                try Task.checkCancellation()
                replay = result
                image = decoded; player = video; started = true
                remaining = max(1, min(60, Int(loaded.grant.duration.rounded(.up))))
                video?.play()
                while remaining > 0 {
                    try await Task.sleep(for: .seconds(1))
                    remaining = max(0, remaining - 1)
                }
                image = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
                if result.replayToken != nil, let deadline = result.replayDeadline, Double(deadline) / 1000 > Date().timeIntervalSince1970 {
                    awaitingReplay = true
                    while Double(deadline) / 1000 > Date().timeIntervalSince1970 {
                        try await Task.sleep(for: .seconds(1))
                    }
                }
                dismiss()
            } catch {
                if !Task.isCancelled { clear(); self.error = error.localizedDescription }
            }
        }
        .onDisappear { clear() }
        .onChange(of: scenePhase) { _, phase in if started && phase != .active { dismiss() } }
    }

    private func clear() {
        image = nil; player?.pause(); player?.replaceCurrentItem(with: nil); player = nil
        if let prepared { service.discard(prepared) }
        prepared = nil
    }
}
