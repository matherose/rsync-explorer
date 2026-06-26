import Foundation

/// Persists computed folder sizes across launches. Sizes are stable (snapshots are
/// immutable), so an entry never goes stale — we just accumulate. Backed by a small
/// JSON file in Application Support, loaded once at init and written through on `set`.
@MainActor
final class FolderSizeStore {
    private var map: [String: FolderSize]
    private let url: URL

    convenience init(filename: String = "folder-sizes.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        self.init(fileURL: dir.appendingPathComponent(filename))
    }

    /// Explicit file location (used by tests).
    init(fileURL: URL) {
        url = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: FolderSize].self, from: data) {
            map = saved
        } else {
            map = [:]
        }
    }

    func size(for path: String) -> FolderSize? { map[path] }

    func set(_ size: FolderSize, for path: String) {
        map[path] = size
        // Small file, written infrequently (once per completed `du`); atomic so a crash
        // mid-write can't corrupt it.
        if let data = try? JSONEncoder().encode(map) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
