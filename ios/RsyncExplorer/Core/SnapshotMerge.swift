import Foundation

enum SnapshotMerge {
    struct Item: Identifiable {
        let entry: RemoteEntry
        let isDeleted: Bool
        var id: String { (isDeleted ? "del:" : "cur:") + entry.path }
    }

    /// Unions folder listings across snapshots (ordered newest -> oldest). Each name
    /// appears once, represented by the newest snapshot that still has it; `isDeleted`
    /// is true when the name is absent from the newest snapshot (listings.first).
    static func merge(_ listings: [[RemoteEntry]]) -> [Item] {
        guard let newest = listings.first else { return [] }
        let newestNames = Set(newest.map(\.name))
        var seen = Set<String>()
        var result: [Item] = []
        for listing in listings {              // newest -> oldest
            for e in listing where !seen.contains(e.name) {
                seen.insert(e.name)
                result.append(Item(entry: e, isDeleted: !newestNames.contains(e.name)))
            }
        }
        return result
    }
}
