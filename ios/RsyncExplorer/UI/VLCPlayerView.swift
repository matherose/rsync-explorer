import SwiftUI
import VLCKitSPM

/// A selectable audio or subtitle track. `id` is VLC's track index (-1 = "Disable").
struct MediaTrack: Identifiable, Equatable {
    let id: Int
    let name: String
}

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
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudioTrackID: Int = -1
    @Published var currentSubtitleTrackID: Int = -1
    var isSeeking = false
    private var started = false

    /// True once there's more than one audio track or any selectable subtitle.
    var hasSelectableTracks: Bool { audioTracks.count > 1 || subtitleTracks.count > 1 }

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

    func selectAudioTrack(_ id: Int) {
        player.currentAudioTrackIndex = Int32(id)
        currentAudioTrackID = id
    }
    func selectSubtitleTrack(_ id: Int) {
        player.currentVideoSubTitleIndex = Int32(id)
        currentSubtitleTrackID = id
    }

    /// Reads the available/selected audio + subtitle tracks from VLC. They only
    /// exist once the streams are open, so this is called on every state change.
    private func refreshTracks() {
        let audioIDs = (player.audioTrackIndexes as? [NSNumber]) ?? []
        let audioNames = (player.audioTrackNames as? [String]) ?? []
        audioTracks = zip(audioIDs, audioNames).map { MediaTrack(id: $0.intValue, name: $1) }
        currentAudioTrackID = Int(player.currentAudioTrackIndex)

        let subIDs = (player.videoSubTitlesIndexes as? [NSNumber]) ?? []
        let subNames = (player.videoSubTitlesNames as? [String]) ?? []
        subtitleTracks = zip(subIDs, subNames).map { MediaTrack(id: $0.intValue, name: $1) }
        currentSubtitleTrackID = Int(player.currentVideoSubTitleIndex)
    }

    // MARK: VLCMediaPlayerDelegate
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async {
            self.isPlaying = self.player.isPlaying
            self.refreshTracks()
        }
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
