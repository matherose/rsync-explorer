import Foundation

enum DeletionDiff {
    /// Entries present in `previous` but absent from `latest` (compared by name) —
    /// i.e. files/folders deleted since the previous snapshot.
    static func deleted(latest: [RemoteEntry], previous: [RemoteEntry]) -> [RemoteEntry] {
        let latestNames = Set(latest.map(\.name))
        return previous.filter { !latestNames.contains($0.name) }
    }
}
