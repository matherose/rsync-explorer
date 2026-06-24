import SwiftUI
import VLCKitSPM

/// Wraps VLCMediaPlayer and republishes playback state + (for audio) parsed metadata.
final class VLCPlayerModel: NSObject, ObservableObject, VLCMediaPlayerDelegate, VLCMediaDelegate {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var position: Double = 0      // 0...1
    @Published var timeMs: Int = 0
    @Published var lengthMs: Int = 0
    @Published var artwork: UIImage?
    @Published var title: String?
    @Published var artist: String?
    var isSeeking = false
    private var started = false

    func attach(url: URL, to view: UIView, fetchMetadata: Bool = false) {
        guard !started else { return }
        started = true
        AudioSession.activatePlayback()   // play through the silent switch + allow background audio
        let media = VLCMedia(url: url)
        if fetchMetadata { media.delegate = self }   // playback parses -> metadata + artwork
        player.drawable = view
        player.delegate = self
        player.media = media
        player.play()
    }

    func playPause() { player.isPlaying ? player.pause() : player.play() }
    func seek(fraction: Double) { player.position = Float(max(0, min(1, fraction))) }
    func stop() { player.stop() }

    // MARK: VLCMediaPlayerDelegate
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { self.isPlaying = self.player.isPlaying }
    }
    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async {
            if !self.isSeeking {
                self.position = Double(self.player.position)
                self.timeMs = Int(self.player.time.intValue)
            }
            let len = Int(self.player.media?.length.intValue ?? 0)
            if len > 0 { self.lengthMs = len }
            else if self.position > 0.01 { self.lengthMs = Int(Double(self.timeMs) / self.position) }
        }
    }

    // MARK: VLCMediaDelegate
    func mediaDidFinishParsing(_ aMedia: VLCMedia) { readMeta(aMedia) }
    func mediaMetaDataDidChange(_ aMedia: VLCMedia) { readMeta(aMedia) }

    private func readMeta(_ media: VLCMedia) {
        let meta = media.metaData
        let art = meta.artwork
        let t = meta.title
        let a = meta.artist
        DispatchQueue.main.async {
            if let art { self.artwork = art }
            if let t, !t.isEmpty { self.title = t }
            if let a, !a.isEmpty { self.artist = a }
        }
    }
}

struct VLCDrawableView: UIViewRepresentable {
    let model: VLCPlayerModel
    let url: URL
    var fetchMetadata: Bool = false

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        model.attach(url: url, to: view, fetchMetadata: fetchMetadata)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
