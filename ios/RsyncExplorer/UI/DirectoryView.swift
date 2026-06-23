import SwiftUI

struct DirRoute: Hashable {
    let relPath: String
    let title: String
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", date = "Date", size = "Size"
    var id: String { rawValue }
}

/// One folder, merged across every snapshot. List or grid; Files-app navigation;
/// tap media opens the carousel. Sort / type-filter / name-search applied locally.
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
    @State private var gridMode = false
    @State private var infoItem: SnapshotMerge.Item?
    @State private var searchResults: [SearchHit]?
    @State private var searching = false

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

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
        Group {
            if let hits = searchResults { searchList(hits) }
            else if gridMode { gridContent }
            else { listContent }
        }
        .overlay { if (loading && allItems.isEmpty) || searching { ProgressView() } }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search — press return for subfolders")
        .onSubmit(of: .search) { Task { await deepSearch() } }
        .onChange(of: searchText) { _, value in if value.isEmpty { searchResults = nil } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { gridMode.toggle() } label: {
                    Image(systemName: gridMode ? "list.bullet" : "square.grid.2x2")
                }
                sortFilterMenu
            }
        }
        .task { await load() }
        .sheet(item: $infoItem) { FileInfoView(item: $0) }
    }

    private var listContent: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            ForEach(displayedItems) { item in
                if item.entry.isDirectory {
                    NavigationLink(value: DirRoute(relPath: childRel(item.entry.name), title: item.entry.name)) {
                        DirectoryRow(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails)
                    }
                    .contextMenu { infoButton(item) }
                } else {
                    Button { open(item) } label: {
                        DirectoryRow(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { fileMenu(item) }
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load() }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(displayedItems) { item in
                    if item.entry.isDirectory {
                        NavigationLink(value: DirRoute(relPath: childRel(item.entry.name), title: item.entry.name)) {
                            DirectoryGridCell(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { infoButton(item) }
                    } else {
                        Button { open(item) } label: {
                            DirectoryGridCell(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { fileMenu(item) }
                    }
                }
            }
            .padding(8)
        }
        .refreshable { await load() }
    }

    @ViewBuilder private func fileMenu(_ item: SnapshotMerge.Item) -> some View {
        Button { open(item) } label: { Label("Open", systemImage: "eye") }
        Button { onDownload(item.entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
        infoButton(item)
    }

    private func infoButton(_ item: SnapshotMerge.Item) -> some View {
        Button { infoItem = item } label: { Label("Info", systemImage: "info.circle") }
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

    private func deepSearch() async {
        guard !searchText.isEmpty, let root = snapshotRoots.first else { return }
        searching = true
        defer { searching = false }
        searchResults = await RecursiveSearch.run(query: searchText, baseRel: relPath,
                                                   root: root, service: service)
    }

    @ViewBuilder private func searchList(_ hits: [SearchHit]) -> some View {
        List {
            if hits.isEmpty {
                Text("No matches in this folder or its subfolders.").foregroundStyle(.secondary)
            }
            ForEach(hits) { hit in
                if hit.entry.isDirectory {
                    NavigationLink(value: DirRoute(relPath: hit.relPath, title: hit.entry.name)) {
                        searchRow(hit)
                    }
                } else {
                    Button { openHit(hit) } label: { searchRow(hit) }.buttonStyle(.plain)
                }
            }
        }
        .listStyle(.plain)
    }

    private func searchRow(_ hit: SearchHit) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: hit.entry)).frame(width: 28).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.entry.name).lineLimit(1)
                Text(hit.location.isEmpty ? "/" : hit.location)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func openHit(_ hit: SearchHit) {
        if hit.entry.kind.isMedia {
            media = .media(items: [hit.entry], start: hit.entry)
        } else {
            media = .quicklook(hit.entry)
        }
    }

    private func icon(for entry: RemoteEntry) -> String {
        switch entry.kind {
        case .folder: "folder.fill"
        case .image: "photo"
        case .video: "play.rectangle.fill"
        case .audio: "music.note"
        case .other: "doc"
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
