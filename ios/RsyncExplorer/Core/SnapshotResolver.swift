import Foundation

enum SnapshotResolver {
    /// Picks the newest snapshot directory: latest mtime, tie-broken by name descending.
    static func latest(from entries: [RemoteEntry]) -> RemoteEntry? {
        entries
            .filter { $0.isDirectory }
            .max { a, b in
                let ta = a.modificationDate ?? .distantPast
                let tb = b.modificationDate ?? .distantPast
                if ta != tb { return ta < tb }
                return a.name < b.name
            }
    }
}
