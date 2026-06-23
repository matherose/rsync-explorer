import SwiftUI

struct DirRoute: Hashable {
    let relPath: String
    let title: String
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", date = "Date", size = "Size"
    var id: String { rawValue }
}

/// One folder, merged across every snapshot. Files-app navigation; tap media opens
/// the carousel. Sort / type-filter / name-search applied locally over the listing.
struct DirectoryView: View {
    let relPath: String
    let title: String
    let service: SFTPService
    let snapshotRoots: [String]
    let thumbnails: ThumbnailService
    @Binding var media: MediaPresentation?
    let onDownload: (RemoteEntry) -> Void

    @State private var allItems: [SnapshotMerge.Item] = []
    @State private var loading = true
    @State private var error: String?

    @State private var sortKey: SortKey = .name
    @State private var ascending = true
    @State private var enabledKinds: Set<FileKind> = [.image, .video, .audio, .other]
    @State private var searchText = ""

    private var displayedItems: [SnapshotMerge.Item] {
        let filtered = allItems.filter { item in
            let kindOK = item.entry.isDirectory || enabledKinds.contains(item.entry.kind)
            let searchOK = searchText.isEmpty
                || item.entry.name.localizedCaseInsensitiveContains(searchText)
            return kindOK && searchOK
        }
        return filtered.sorted { a, b in
            if a.entry.isDirectory != b.entry.isDirectory { return a.entry.isDirectory }
            return ascending ? keyLess(a, b) : keyLess(b, a)
        }
    }

    private func keyLess(_ a: SnapshotMerge.Item, _ b: SnapshotMerge.Item) -> Bool {
        switch sortKey {
        case .name: return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        case .date: return (a.entry.modificationDate ?? .distantPast) < (b.entry.modificationDate ?? .distantPast)
        case .size: return a.entry.size < b.entry.size
        }
    }

    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(displayedItems) { item in row(item) }
        }
        .listStyle(.plain)
        .overlay { if loading && allItems.isEmpty { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search this folder")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { sortFilterMenu } }
        .refreshable { await load() }
        .task { await load() }
    }

    private var sortFilterMenu: some View {
        Menu {
            Picker("Sort by", selection: $sortKey) {
                ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
            }
            Button { ascending.toggle() } label: {
                Label(ascending ? "Ascending" : "Descending",
                      systemImage: ascending ? "arrow.up" : "arrow.down")
            }
            Divider()
            Section("Show") {
                Toggle("Photos", isOn: kindBinding(.image))
                Toggle("Videos", isOn: kindBinding(.video))
                Toggle("Audio", isOn: kindBinding(.audio))
                Toggle("Other files", isOn: kindBinding(.other))
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
        }
    }

    private func kindBinding(_ kind: FileKind) -> Binding<Bool> {
        Binding(get: { enabledKinds.contains(kind) },
                set: { on in if on { enabledKinds.insert(kind) } else { enabledKinds.remove(kind) } })
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
                Button { onDownload(item.entry) } label: {
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
            let mediaItems = displayedItems.filter { $0.entry.kind.isMedia }.map(\.entry)
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
        allItems = SnapshotMerge.merge(listings)
        error = (allItems.isEmpty && !snapshotRoots.isEmpty) ? "Empty folder." : nil
    }
}
