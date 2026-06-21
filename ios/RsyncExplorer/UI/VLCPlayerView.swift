import SwiftUI
import VLCKitSPM

/// Plays a local file URL through MobileVLCKit (FFmpeg decode, VideoToolbox HW
/// + software fallback, Metal/GPU render). Used full-screen.
struct VLCPlayerView: View {
    let url: URL
    var onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VLCPlayerContainer(url: url).ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding()
            }
        }
        .background(.black)
    }
}

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
