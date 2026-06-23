import Foundation

/// Loads lyrics for an audio file from a sibling `.lrc` (e.g. song.mp3 -> song.lrc).
enum LyricsLoader {
    static func loadLRC(for entry: RemoteEntry, via service: SFTPService) async -> [LyricLine]? {
        let lrcPath = (entry.path as NSString).deletingPathExtension + ".lrc"
        guard let data = try? await service.read(at: lrcPath, offset: 0, length: 512 * 1024),
              !data.isEmpty else { return nil }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        guard let text else { return nil }
        let lines = LRCParser.parse(text)
        return lines.isEmpty ? nil : lines
    }
}
