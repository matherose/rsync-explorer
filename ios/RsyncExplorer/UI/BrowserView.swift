import SwiftUI

struct BrowserSession {
    let service: SFTPService
    let context: SnapshotResolver.Context
}

enum MediaPresentation: Identifiable {
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

struct BrowserView: View {
    let session: BrowserSession
    var onDisconnect: () -> Void

    @StateObject private var root: TreeNode
    @State private var media: MediaPresentation?

    init(session: BrowserSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.onDisconnect = onDisconnect
        let rootEntry = RemoteEntry(name: "Backup", path: session.context.latestRoot,
                                    isDirectory: true, size: 0, modificationDate: nil)
        _root = StateObject(wrappedValue: TreeNode(entry: rootEntry, isDeleted: false,
                                                   latestRoot: session.context.latestRoot,
                                                   previousRoot: session.context.previousRoot))
    }

    var body: some View {
        NavigationStack {
            List {
                if root.isLoading && root.children.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
                ForEach(root.children) { child in
                    TreeNodeView(node: child,
                                 service: session.service,
                                 siblingImages: root.imageChildren,
                                 onOpenImage: { media = .images(items: $1, start: $0) },
                                 onOpenVideo: { media = .video($0) },
                                 onOpenOther: { media = .quicklook($0) })
                }
            }
            .listStyle(.plain)
            .navigationTitle("Backup")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect") {
                        Task { await session.service.disconnect(); onDisconnect() }
                    }
                }
            }
            .task { await root.loadIfNeeded(service: session.service) }
            .fullScreenCover(item: $media) { mediaView($0) }
        }
    }

    @ViewBuilder private func mediaView(_ p: MediaPresentation) -> some View {
        switch p {
        case .images(let items, let start):
            MediaCarouselView(service: session.service, images: items, start: start) { media = nil }
        case .video(let e):
            VideoPlayerView(service: session.service, entry: e) { media = nil }
        case .quicklook(let e):
            QuickLookView(service: session.service, entry: e) { media = nil }
        }
    }
}
