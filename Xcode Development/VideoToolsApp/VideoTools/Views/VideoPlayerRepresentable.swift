import AVKit
import SwiftUI

// MARK: - Video Player NSView Wrapper

/// Wraps `AVPlayerView` for use in SwiftUI with custom transport controls.
/// `controlsStyle` is set to `.none` — the parent view provides all playback UI.
struct VideoPlayerRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
