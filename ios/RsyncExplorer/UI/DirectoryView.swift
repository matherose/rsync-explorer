import SwiftUI

struct DirRoute: Hashable {
    let path: String
    let latestRoot: String
    let previousRoot: String?
    let title: String
}

struct DirEntry: Identifiable {
    let entry: RemoteEntry
    let isDeleted: Bool
    var id: String { (isDeleted ? "del:" : "cur:") + entry.path }
}

private enum MediaPresentation: Identifiable {
    case images(items: [RemoteEntry], start: RemoteEntry)
    case video(RemoteEntry)
    case quicklook(RemoteEntry)

    var id: String {
        switch self {
        case .images(_, let s): return "img:" + s.path
        case .video(let e): return "vid:" + e.path
        case .quicklook(let e): return "ql:" + e.path
        }
    }
}

struct DirectoryView: View {
    let route: DirRoute
    let service: SFTPService

    @State private var rows: [DirEntry] = []
    @State private var loading = true
    @State private var error: String?
    @State private var media: MediaPresentation?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(rows) { row in rowView(row) }
        }
        .overlay { if loading && rows.isEmpty { ProgressView() } }
        .navigationTitle(route.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
        .fullScreenCover(item: $media) { mediaView($0) }
    }

    @ViewBuilder private func rowView(_ row: DirEntry) -> some View {
        if row.entry.isDirectory {
            NavigationLink(value: childRoute(for: row)) {
                DirectoryRow(entry: row.entry, isDeleted: row.isDeleted)
            }
        } else {
            Button { open(row) } label: {
                DirectoryRow(entry: row.entry, isDeleted: row.isDeleted)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func mediaView(_ p: MediaPresentation) -> some View {
        switch p {
        case .images(let items, let start):
            MediaCarouselView(service: service, images: items, start: start) { media = nil }
        case .video(let e):
            VideoPlayerView(service: service, entry: e) { media = nil }
        case .quicklook(let e):
            QuickLookView(service: service, entry: e) { media = nil }
        }
    }

    private func childRoute(for row: DirEntry) -> DirRoute {
        if row.isDeleted {
            // Deleted folder lives only in the previous snapshot; browse it directly,
            // with no further deletion detection.
            return DirRoute(path: row.entry.path, latestRoot: row.entry.path,
                            previousRoot: nil, title: row.entry.name)
        }
        return DirRoute(path: row.entry.path, latestRoot: route.latestRoot,
                        previousRoot: route.previousRoot, title: row.entry.name)
    }

    private func open(_ row: DirEntry) {
        switch row.entry.kind {
        case .image:
            let images = rows.filter { $0.entry.kind == .image }.map(\.entry)
            media = .images(items: images, start: row.entry)
        case .video:
            media = .video(row.entry)
        default:
            media = .quicklook(row.entry)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let latest = try await service.listDirectory(route.path)
            var previous: [RemoteEntry] = []
            if let pr = route.previousRoot {
                let rel = Self.relativePath(route.path, under: route.latestRoot)
                let prevFolder = rel.isEmpty ? pr : pr + "/" + rel
                previous = (try? await service.listDirectory(prevFolder)) ?? []
            }
            let deleted = DeletionDiff.deleted(latest: latest, previous: previous)
            rows = Self.buildRows(latest: latest, deleted: deleted)
            error = nil
        } catch {
            self.error = "Couldn't list this folder. Pull to retry."
        }
    }

    static func relativePath(_ path: String, under root: String) -> String {
        if path == root { return "" }
        if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        return ""
    }

    static func buildRows(latest: [RemoteEntry], deleted: [RemoteEntry]) -> [DirEntry] {
        let existing = latest.map { DirEntry(entry: $0, isDeleted: false) }
        let del = deleted.map { DirEntry(entry: $0, isDeleted: true) }
        return (existing + del).sorted { a, b in
            if a.entry.isDirectory != b.entry.isDirectory { return a.entry.isDirectory }
            return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        }
    }
}
