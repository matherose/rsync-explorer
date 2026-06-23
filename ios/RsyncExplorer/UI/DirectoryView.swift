import SwiftUI

struct DirRoute: Hashable {
    let relPath: String
    let title: String
}

/// One folder, merged across every snapshot (newest -> oldest). Folders push with
/// Files-app-style navigation; tapping a file opens media (video streams). Long-press
/// a file for Download. Deleted items carry a red dot but read normally.
struct DirectoryView: View {
    let relPath: String
    let title: String
    let service: SFTPService
    let snapshotRoots: [String]
    let thumbnails: ThumbnailService
    @Binding var media: MediaPresentation?
    let onDownload: (RemoteEntry) -> Void

    @State private var items: [SnapshotMerge.Item] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(items) { item in row(item) }
        }
        .listStyle(.plain)
        .overlay { if loading && items.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder private func row(_ item: SnapshotMerge.Item) -> some View {
        if item.entry.isDirectory {
            NavigationLink(value: DirRoute(relPath: childRel(item.entry.name), title: item.entry.name)) {
                DirectoryRow(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails)
            }
        } else {
            Button { open(item) } label: {
                DirectoryRow(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails)
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    onDownload(item.entry)
                } label: {
                    Label("Download", systemImage: "arrow.down.circle")
                }
            }
        }
    }

    private func childRel(_ name: String) -> String {
        relPath.isEmpty ? name : relPath + "/" + name
    }

    private func open(_ item: SnapshotMerge.Item) {
        if item.entry.kind.isMedia {
            let mediaItems = items.filter { $0.entry.kind.isMedia }.map(\.entry)
            media = .media(items: mediaItems, start: item.entry)
        } else {
            media = .quicklook(item.entry)
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var listings: [[RemoteEntry]] = []
        for root in snapshotRoots {
            let folder = relPath.isEmpty ? root : root + "/" + relPath
            let entries = (try? await service.listDirectory(folder)) ?? []
            listings.append(entries)
        }
        let merged = SnapshotMerge.merge(listings)
        items = merged.sorted { a, b in
            if a.entry.isDirectory != b.entry.isDirectory { return a.entry.isDirectory }
            return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        }
        error = (items.isEmpty && !snapshotRoots.isEmpty) ? "Empty folder." : nil
    }
}
