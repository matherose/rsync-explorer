import Foundation

/// Finds external "sidecar" subtitle files sitting next to a video (same basename,
/// e.g. Movie.mkv -> Movie.srt) and downloads them so they can be handed to VLC as
/// playback slaves. Embedded subtitle tracks are handled by VLC directly.
enum SubtitleLoader {
    static let extensions = ["srt", "ass", "ssa", "vtt", "sub"]

    static func sidecarSubtitles(for entry: RemoteEntry, via service: SFTPService) async -> [URL] {
        guard !entry.isDirectory else { return [] }
        let base = (entry.path as NSString).deletingPathExtension

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var urls: [URL] = []
        for ext in extensions {
            let remote = base + "." + ext
            let key = CacheKey.make(path: remote, size: 0, mtime: 0)
            let local = dir.appendingPathComponent(key).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: local.path) {
                urls.append(local)
                continue
            }
            // A missing sibling throws SFTPError.errorStatus (no reconnect) — just skip it.
            if (try? await service.download(remote, to: local, progress: { _ in })) != nil {
                urls.append(local)
            }
        }
        return urls
    }
}
