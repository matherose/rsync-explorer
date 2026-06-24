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

    /// True for names beginning `YYYY-MM-DD` (rsync dated snapshot folders).
    static func isDatedSnapshot(_ name: String) -> Bool {
        name.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil
    }

    /// Dated snapshot directories, newest first (mtime desc, tiebreak name desc).
    static func datedSnapshots(from entries: [RemoteEntry]) -> [RemoteEntry] {
        entries
            .filter { $0.isDirectory && isDatedSnapshot($0.name) }
            .sorted { a, b in
                let ta = a.modificationDate ?? .distantPast
                let tb = b.modificationDate ?? .distantPast
                if ta != tb { return ta > tb }
                return a.name > b.name
            }
    }

    struct Context: Equatable {
        let latestRoot: String      // where browsing starts
        let previousRoot: String?   // for deletion detection (nil if only one snapshot)
    }

    /// Resolves the browse root (the `latest` symlink if present, else the newest
    /// dated dir) and the previous-snapshot root (second-newest dated dir).
    static func context(remotePath: String, entries: [RemoteEntry]) -> Context {
        let base = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        let dated = datedSnapshots(from: entries)
        let hasLatest = entries.contains { $0.name == "latest" }
        let latestRoot = hasLatest ? base + "/latest" : (dated.first?.path ?? base)
        let previousRoot = dated.count > 1 ? dated[1].path : nil
        return Context(latestRoot: latestRoot, previousRoot: previousRoot)
    }

    /// Joins a directory and a child name with a single separator.
    static func join(_ base: String, _ name: String) -> String {
        base.hasSuffix("/") ? base + name : base + "/" + name
    }

    /// The snapshot a path belongs to: the last component of the matching root
    /// (e.g. "2026-06-12_02-00" or "latest"). nil if the path is under no root.
    static func snapshotName(forPath path: String, roots: [String]) -> String? {
        guard let root = roots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) else { return nil }
        return (root as NSString).lastPathComponent
    }

    /// The parent directory of a path. "/a/b/c" -> "/a/b", "/foo" -> "/", "/" -> "/".
    static func parentPath(_ path: String) -> String {
        let p = (path.count > 1 && path.hasSuffix("/")) ? String(path.dropLast()) : path
        guard let idx = p.lastIndex(of: "/") else { return p }
        return idx == p.startIndex ? "/" : String(p[..<idx])
    }
}
