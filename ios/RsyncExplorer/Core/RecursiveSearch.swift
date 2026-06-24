import Foundation

struct SearchHit: Identifiable {
    let entry: RemoteEntry
    let relPath: String      // path relative to the snapshot root
    let isDeleted: Bool      // absent from the newest snapshot (matches the red dot)
    var id: String { (entry.isDirectory ? "d:" : "f:") + relPath }
    var location: String { (relPath as NSString).deletingLastPathComponent }
}

/// Recursively searches the UNION of every snapshot for names matching `query`.
///
/// For each folder it lists that folder in *all* snapshot roots and runs the same
/// `SnapshotMerge` the browser uses, so results include files that exist only in
/// older snapshots (deleted items, flagged `isDeleted`). Matching is a
/// case-insensitive substring test — the equivalent of `find -iname "*query*"`,
/// so spaces are honoured and partial names match. The walk is breadth-first and
/// bounded by a time budget, a folder cap and a result cap so it can't run away on
/// a large backup, and it bails out promptly when the Task is cancelled.
enum RecursiveSearch {
    static func run(query: String,
                    baseRel: String,
                    roots: [String],
                    service: SFTPService,
                    maxFolders: Int = 6000,
                    maxResults: Int = 500,
                    timeLimit: TimeInterval = 25) async -> [SearchHit] {
        guard !query.isEmpty, !roots.isEmpty else { return [] }
        let deadline = Date().addingTimeInterval(timeLimit)

        var results: [SearchHit] = []
        var queue: [String] = [baseRel]      // BFS frontier of relative folder paths
        var foldersScanned = 0

        while !queue.isEmpty {
            if Task.isCancelled { break }
            if foldersScanned >= maxFolders || results.count >= maxResults { break }
            if Date() >= deadline { break }

            let rel = queue.removeFirst()
            foldersScanned += 1

            // List this folder in every snapshot, then merge to the union view.
            var listings: [[RemoteEntry]] = []
            for root in roots {
                let path = rel.isEmpty ? root : root + "/" + rel
                let entries = (try? await service.listDirectory(path)) ?? []
                listings.append(entries)
            }

            for item in SnapshotMerge.merge(listings) {
                let e = item.entry
                let childRel = rel.isEmpty ? e.name : rel + "/" + e.name
                if e.name.localizedCaseInsensitiveContains(query) {
                    results.append(SearchHit(entry: e, relPath: childRel, isDeleted: item.isDeleted))
                }
                if e.isDirectory { queue.append(childRel) }
            }
        }

        return results.sorted {
            $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending
        }
    }
}
