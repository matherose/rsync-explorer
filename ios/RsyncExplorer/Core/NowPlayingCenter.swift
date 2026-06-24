import Foundation
import MediaPlayer
import AVFoundation
import UIKit

/// Bridges the active player to the system: populates the lock screen / Control
/// Center "Now Playing" info, routes remote commands (play/pause/scrub) back to it,
/// and pauses/resumes around audio interruptions (e.g. a phone call). Used from the
/// main thread only.
final class NowPlayingCenter {
    static let shared = NowPlayingCenter()

    private weak var model: VLCPlayerModel?
    private var configured = false
    private var interruptionObserver: NSObjectProtocol?

    /// Makes `model` the target of remote commands and Now Playing updates.
    func setActive(_ model: VLCPlayerModel) {
        self.model = model
        configureCommandsIfNeeded()
        observeInterruptionsIfNeeded()
    }

    /// Clears Now Playing if `model` is still the active one (no-op otherwise).
    func clear(if model: VLCPlayerModel) {
        guard self.model === model else { return }
        self.model = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// Pushes current playback info — ignored unless `model` is the active one, so a
    /// just-swiped-away page can't clobber the newly active one.
    func update(from model: VLCPlayerModel, title: String, artist: String?, artwork: UIImage?,
                durationMs: Int, elapsedMs: Int, isPlaying: Bool) {
        guard self.model === model else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: title]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(durationMs) / 1000 }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(elapsedMs) / 1000
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureCommandsIfNeeded() {
        guard !configured else { return }
        configured = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            self?.model?.player.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.model?.player.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.model?.playPause(); return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let model = self?.model, model.lengthMs > 0,
                  let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            model.seek(fraction: event.positionTime / (Double(model.lengthMs) / 1000))
            return .success
        }
    }

    private func observeInterruptionsIfNeeded() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self?.model?.player.pause()
            case .ended:
                if let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                   AVAudioSession.InterruptionOptions(rawValue: optRaw).contains(.shouldResume) {
                    self?.model?.player.play()
                }
            @unknown default:
                break
            }
        }
    }
}
