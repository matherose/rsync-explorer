import SwiftUI

struct DirRoute: Hashable {
    let relPath: String
    let title: String
}

enum SortKey: String, CaseIterable, Identifiable {
    case name = "Name", date = "Date", size = "Size"
    var id: String { rawValue }
}

enum SizeFilter: String, CaseIterable, Identifiable {
    case none = "Any size", mb1 = "≥ 1 MB", mb10 = "≥ 10 MB", mb100 = "≥ 100 MB", gb1 = "≥ 1 GB"
    var id: String { rawValue }
    var minBytes: Int64 {
        switch self {
        case .none: return 0
        case .mb1:  return 1_000_000
        case .mb10: return 10_000_000
        case .mb100: return 100_000_000
        case .gb1:  return 1_000_000_000
        }
    }
}

/// One folder, merged across every snapshot. List or grid; Files-app navigation;
/// tap media opens the carousel. Sort / type-filter / name-search applied locally.
struct DirectoryView: View {
    let relPath: String
    let title: String
    let service: SFTPService
    let snapshotRoots: [String]
    let thumbnails: ThumbnailService
    let cache: DirectoryCache
    @Binding var media: MediaPresentation?
    let onDownload: (RemoteEntry) -> Void

    @State private var allItems: [SnapshotMerge.Item] = []
    @State private var loading = true
    @State private var loadFailed = false

    // View preferences persist across folders and launches (the type filter stays
    // per-session on purpose — a remembered hidden filter is a "where are my files?" trap).
    @AppStorage("dir.sortKey") private var sortKey: SortKey = .name
    @AppStorage("dir.ascending") private var ascending = true
    @AppStorage("dir.gridMode") private var gridMode = false
    @State private var enabledKinds: Set<FileKind> = [.image, .video, .audio, .other]
    @State private var minSize: SizeFilter = .none
    @State private var searchText = ""
    @State private var infoItem: SnapshotMerge.Item?
    @State private var searchResults: [SearchHit]?
    @State private var searching = false
    @State private var searchTask: Task<Void, Never>?
    // Folder sizes are computed on demand (recursive `du` on the NAS) and cached here
    // per path — safe to keep for the session since snapshots are immutable.
    @State private var folderSizes: [String: FolderSize] = [:]
    @State private var calculatingPaths: Set<String> = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 8)]

    private var displayedItems: [SnapshotMerge.Item] {
        let filtered = allItems.filter { item in
            let kindOK = item.entry.isDirectory || enabledKinds.contains(item.entry.kind)
            let searchOK = searchText.isEmpty
                || item.entry.name.localizedCaseInsensitiveContains(searchText)
            // Folders with an un-computed size stay visible so the filter never hides
            // something you haven't measured yet.
            let sizeOK = minSize == .none || (effectiveSize(item).map { $0 >= minSize.minBytes } ?? true)
            return kindOK && searchOK && sizeOK
        }
        return filtered.sorted { a, b in
            if a.entry.isDirectory != b.entry.isDirectory { return a.entry.isDirectory }
            return ascending ? keyLess(a, b) : keyLess(b, a)
        }
    }

    /// The size used for sorting/filtering: a file's own size, or a folder's computed
    /// size (nil until calculated on demand). A partial folder size counts as its
    /// lower bound.
    private func effectiveSize(_ item: SnapshotMerge.Item) -> Int64? {
        item.entry.isDirectory ? folderSizes[item.entry.path]?.bytes : item.entry.size
    }

    private func keyLess(_ a: SnapshotMerge.Item, _ b: SnapshotMerge.Item) -> Bool {
        switch sortKey {
        case .name: return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        case .date: return (a.entry.modificationDate ?? .distantPast) < (b.entry.modificationDate ?? .distantPast)
        case .size: return (effectiveSize(a) ?? -1) < (effectiveSize(b) ?? -1)
        }
    }

    var body: some View {
        Group {
            if let hits = searchResults { searchList(hits) }
            else if gridMode { gridContent }
            else { listContent }
        }
        .overlay { statusOverlay }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search — press return for subfolders")
        .onSubmit(of: .search) {
            searchTask?.cancel()
            searchTask = Task { await deepSearch() }
        }
        .onChange(of: searchText) { _, value in
            if value.isEmpty { searchTask?.cancel(); searchResults = nil }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { gridMode.toggle() } label: {
                    Image(systemName: gridMode ? "list.bullet" : "square.grid.2x2")
                }
                sortFilterMenu
            }
        }
        .task { await load() }
        .sheet(item: $infoItem) {
            FileInfoView(item: $0, snapshotRoots: snapshotRoots, folderSize: folderSizes[$0.entry.path])
        }
    }

    @ViewBuilder private var statusOverlay: some View {
        if searching || (loading && allItems.isEmpty) {
            ProgressView()
        } else if loadFailed && allItems.isEmpty {
            ContentUnavailableView {
                Label("Couldn’t load this folder", systemImage: "wifi.exclamationmark")
            } description: {
                Text("The connection may have dropped.")
            } actions: {
                Button("Retry") { Task { await load(forceRefresh: true) } }
            }
        } else if allItems.isEmpty && searchResults == nil {
            ContentUnavailableView("Empty folder", systemImage: "folder")
        }
    }

    private var listContent: some View {
        List {
            ForEach(displayedItems) { item in
                if item.entry.isDirectory {
                    NavigationLink(value: DirRoute(relPath: childRel(item.entry.name), title: item.entry.name)) {
                        DirectoryRow(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails,
                                     folderSize: folderSizes[item.entry.path],
                                     calculating: calculatingPaths.contains(item.entry.path))
                    }
                    .contextMenu { folderMenu(item) }
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
        .refreshable { await load(forceRefresh: true) }
    }

    private var gridContent: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(displayedItems) { item in
                    if item.entry.isDirectory {
                        NavigationLink(value: DirRoute(relPath: childRel(item.entry.name), title: item.entry.name)) {
                            DirectoryGridCell(entry: item.entry, isDeleted: item.isDeleted, thumbnails: thumbnails,
                                              folderSize: folderSizes[item.entry.path])
                        }
                        .buttonStyle(.plain)
                        .contextMenu { folderMenu(item) }
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
        .refreshable { await load(forceRefresh: true) }
    }

    @ViewBuilder private func fileMenu(_ item: SnapshotMerge.Item) -> some View {
        Button { open(item) } label: { Label("Open", systemImage: "eye") }
        Button { onDownload(item.entry) } label: { Label("Download", systemImage: "arrow.down.circle") }
        infoButton(item)
    }

    @ViewBuilder private func folderMenu(_ item: SnapshotMerge.Item) -> some View {
        if folderSizes[item.entry.path] == nil {
            Button { Task { await calculateSize(item) } } label: {
                Label("Calculate size", systemImage: "sum")
            }
        }
        infoButton(item)
    }

    /// Computes a folder's recursive size on the NAS (one `du`) and caches it.
    private func calculateSize(_ item: SnapshotMerge.Item) async {
        let path = item.entry.path
        guard item.entry.isDirectory, folderSizes[path] == nil, !calculatingPaths.contains(path) else { return }
        calculatingPaths.insert(path)
        defer { calculatingPaths.remove(path) }
        if let size = await RemoteFolderSize.run(path: path, service: service) {
            folderSizes[path] = size
        }
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
            Picker("Minimum size", selection: $minSize) {
                ForEach(SizeFilter.allCases) { Text($0.rawValue).tag($0) }
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
        guard !searchText.isEmpty else { return }
        searching = true
        defer { searching = false }
        // Prefer fast server-side search (fd/find on the NAS); fall back to the
        // in-app snapshot walk if the host has no usable tool or the command fails.
        var hits = await RemoteSearch.run(query: searchText, baseRel: relPath,
                                          roots: snapshotRoots, service: service)
        if hits == nil {
            hits = await RecursiveSearch.run(query: searchText, baseRel: relPath,
                                             roots: snapshotRoots, service: service)
        }
        if !Task.isCancelled { searchResults = hits }
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
            Spacer(minLength: 8)
            if hit.isDeleted {
                Circle().fill(.red).frame(width: 9, height: 9)
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

    private func load(forceRefresh: Bool = false) async {
        if !forceRefresh, let cached = cache.items(for: relPath) {
            allItems = cached
            loadFailed = false
            loading = false
            return
        }
        loading = true
        defer { loading = false }

        let listings: [[RemoteEntry]]
        if let server = await RemoteListing.run(roots: snapshotRoots, rel: relPath, service: service) {
            // One server-side `find` across all snapshots — one round-trip instead of
            // one per snapshot root.
            listings = server
        } else {
            // Fallback: list each snapshot root over SFTP. A folder may legitimately be
            // absent from older snapshots, so tolerate per-root failures; only a total
            // failure means the connection dropped.
            var acc: [[RemoteEntry]] = []
            var anySucceeded = false
            for root in snapshotRoots {
                let folder = relPath.isEmpty ? root : root + "/" + relPath
                if let entries = try? await service.listDirectory(folder) {
                    acc.append(entries)
                    anySucceeded = true
                } else {
                    acc.append([])
                }
            }
            guard anySucceeded else { loadFailed = true; return }   // don't cache a failure
            listings = acc
        }

        loadFailed = false
        let merged = SnapshotMerge.merge(listings)
        allItems = merged
        cache.set(merged, for: relPath)
    }
}
