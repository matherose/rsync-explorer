import Foundation

struct SearchHit: Identifiable {
    let entry: RemoteEntry
    let relPath: String   // path relative to the snapshot root
    var id: String { (entry.isDirectory ? "d:" : "f:") + entry.path }
    var location: String { (relPath as NSString).deletingLastPathComponent }
}

/// Walks a snapshot subtree over SFTP collecting name matches. Bounded so it can't
/// run away on a huge backup. Scoped to one snapshot root (the latest).
enum RecursiveSearch {
    static func run(query: String, baseRel: String, root: String, service: SFTPService,
                    maxScanned: Int = 5000, maxResults: Int = 400) async -> [SearchHit] {
        guard !query.isEmpty else { return [] }
        var results: [SearchHit] = []
        var stack = [baseRel]
        var scanned = 0
        while let rel = stack.popLast(), scanned < maxScanned, results.count < maxResults {
            let path = rel.isEmpty ? root : root + "/" + rel
            let entries = (try? await service.listDirectory(path)) ?? []
            for e in entries {
                scanned += 1
                let childRel = rel.isEmpty ? e.name : rel + "/" + e.name
                if e.name.localizedCaseInsensitiveContains(query) {
                    results.append(SearchHit(entry: e, relPath: childRel))
                }
                if e.isDirectory { stack.append(childRel) }
            }
        }
        return results.sorted { $0.entry.name.localizedCaseInsensitiveCompare($1.entry.name) == .orderedAscending }
    }
}
