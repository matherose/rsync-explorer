import AVFoundation

/// Configures the shared audio session for media playback so sound plays even
/// with the ring/silent switch on and (with the `audio` background mode in
/// Info.plist) keeps playing when the app is backgrounded.
enum AudioSession {
    static func activatePlayback() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}
