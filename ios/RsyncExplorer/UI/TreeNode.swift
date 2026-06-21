import Foundation

/// One node in the lazily-loaded backup tree. Folders load their children on first
/// expand, computing red-dot deletions (files in the previous snapshot but not here).
@MainActor
final class TreeNode: ObservableObject, Identifiable {
    let entry: RemoteEntry
    let isDeleted: Bool
    private let latestRoot: String
    private let previousRoot: String?

    @Published var children: [TreeNode] = []
    @Published var isExpanded = false
    @Published var isLoading = false
    private(set) var didLoad = false

    nonisolated var id: String { (isDeleted ? "del:" : "cur:") + entry.path }

    init(entry: RemoteEntry, isDeleted: Bool, latestRoot: String, previousRoot: String?) {
        self.entry = entry
        self.isDeleted = isDeleted
        self.latestRoot = latestRoot
        self.previousRoot = previousRoot
    }

    /// Image entries among this folder's children (for the carousel).
    var imageChildren: [RemoteEntry] {
        children.filter { $0.entry.kind == .image }.map(\.entry)
    }

    func loadIfNeeded(service: SFTPService) async {
        guard entry.isDirectory, !didLoad, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        let latest = (try? await service.listDirectory(entry.path)) ?? []
        var previous: [RemoteEntry] = []
        if let pr = previousRoot {
            let rel = Self.relativePath(entry.path, under: latestRoot)
            let prevFolder = rel.isEmpty ? pr : pr + "/" + rel
            previous = (try? await service.listDirectory(prevFolder)) ?? []
        }
        let deleted = DeletionDiff.deleted(latest: latest, previous: previous)

        let rows: [(RemoteEntry, Bool)] =
            latest.map { ($0, false) } + deleted.map { ($0, true) }
        let sorted = rows.sorted { a, b in
            if a.0.isDirectory != b.0.isDirectory { return a.0.isDirectory }
            return a.0.name.localizedCaseInsensitiveCompare(b.0.name) == .orderedAscending
        }
        children = sorted.map { (e, isDel) in
            let deletedChild = isDel || self.isDeleted
            // A deleted subtree only exists in the past: re-root there, no further diffing.
            let childLatestRoot = deletedChild ? e.path : latestRoot
            let childPreviousRoot = deletedChild ? nil : previousRoot
            return TreeNode(entry: e, isDeleted: deletedChild,
                            latestRoot: childLatestRoot, previousRoot: childPreviousRoot)
        }
        didLoad = true
    }

    static func relativePath(_ path: String, under root: String) -> String {
        if path == root { return "" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return ""
    }
}
