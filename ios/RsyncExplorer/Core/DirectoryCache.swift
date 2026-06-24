import Foundation

/// In-memory cache of merged directory listings for the current session, keyed by
/// relative path, so navigating back into a folder is instant. Pull-to-refresh
/// bypasses it. Backups are effectively immutable, so stale entries are low risk.
@MainActor
final class DirectoryCache {
    private var store: [String: [SnapshotMerge.Item]] = [:]

    func items(for relPath: String) -> [SnapshotMerge.Item]? { store[relPath] }
    func set(_ items: [SnapshotMerge.Item], for relPath: String) { store[relPath] = items }
    func clear() { store.removeAll() }
}
