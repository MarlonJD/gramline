import AVKit
import SwiftUI

/// Keep playback in AVKit's native view. The SwiftUI VideoPlayer overlay
/// crashes during metadata initialization on the locally tested macOS runtime.
struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    var restricted = false
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = restricted ? .none : .floating
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = !restricted
        view.allowsVideoFrameAnalysis = !restricted
        view.allowsPictureInPicturePlayback = !restricted
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause(); view.player = nil
    }
}
