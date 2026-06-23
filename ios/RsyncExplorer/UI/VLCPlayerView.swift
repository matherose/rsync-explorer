import SwiftUI
import VLCKitSPM

/// Wraps VLCMediaPlayer and republishes playback state for SwiftUI controls.
final class VLCPlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var position: Double = 0      // 0...1
    @Published var timeMs: Int = 0
    @Published var lengthMs: Int = 0
    var isSeeking = false
    private var started = false

    func attach(url: URL, to view: UIView) {
        guard !started else { return }
        started = true
        player.drawable = view
        player.delegate = self
        player.media = VLCMedia(url: url)
        player.play()
    }

    func playPause() { player.isPlaying ? player.pause() : player.play() }
    func seek(fraction: Double) { player.position = Float(max(0, min(1, fraction))) }
    func stop() { player.stop() }

    func mediaPlayerStateChanged(_ aNotification: Notification!) {
        DispatchQueue.main.async { self.isPlaying = self.player.isPlaying }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        DispatchQueue.main.async {
            if !self.isSeeking {
                self.position = Double(self.player.position)
                self.timeMs = Int(self.player.time.intValue)
            }
            let len = Int(self.player.media?.length.intValue ?? 0)
            if len > 0 {
                self.lengthMs = len
            } else if self.position > 0.01 {
                self.lengthMs = Int(Double(self.timeMs) / self.position)
            }
        }
    }
}

struct VLCDrawableView: UIViewRepresentable {
    let model: VLCPlayerModel
    let url: URL

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        model.attach(url: url, to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
