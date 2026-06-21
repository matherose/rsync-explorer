import SwiftUI
import VLCKitSPM

/// Renders a local file URL through MobileVLCKit (FFmpeg decode, VideoToolbox HW
/// + software fallback, GPU render).
struct VLCPlayerContainer: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        let player = VLCMediaPlayer()
        player.media = VLCMedia(url: url)
        player.drawable = view
        context.coordinator.player = player
        DispatchQueue.main.async { player.play() }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var player: VLCMediaPlayer?
        deinit { player?.stop() }
    }
}
