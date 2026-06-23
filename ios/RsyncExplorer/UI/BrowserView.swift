import SwiftUI

struct BrowserSession {
    let service: SFTPService
    let snapshotRoots: [String]   // newest -> oldest
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

    @State private var media: MediaPresentation?
    @State private var share: ShareItem?
    @State private var streamServer: LocalStreamServer

    init(session: BrowserSession, onDisconnect: @escaping () -> Void) {
        self.session = session
        self.onDisconnect = onDisconnect
        _streamServer = State(initialValue: LocalStreamServer(service: session.service))
    }

    private var thumbnails: ThumbnailService {
        ThumbnailService(service: session.service, streamServer: streamServer)
    }

    var body: some View {
        NavigationStack {
            DirectoryView(relPath: "", title: "All snapshots (\(session.snapshotRoots.count))",
                          service: session.service, snapshotRoots: session.snapshotRoots,
                          thumbnails: thumbnails, media: $media, onDownload: download)
                .navigationDestination(for: DirRoute.self) { route in
                    DirectoryView(relPath: route.relPath, title: route.title,
                                  service: session.service, snapshotRoots: session.snapshotRoots,
                                  thumbnails: thumbnails, media: $media, onDownload: download)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") {
                            Task {
                                await streamServer.shutdown()
                                await session.service.disconnect()
                                onDisconnect()
                            }
                        }
                    }
                }
                .fullScreenCover(item: $media) { mediaView($0) }
                .sheet(item: $share) { ActivityView(url: $0.url) }
        }
    }

    private func download(_ entry: RemoteEntry) {
        Task {
            if let url = try? await FileCache.shared.fetch(entry, via: session.service, progress: { _ in }) {
                await MainActor.run { share = ShareItem(url: url) }
            }
        }
    }

    @ViewBuilder private func mediaView(_ p: MediaPresentation) -> some View {
        switch p {
        case .images(let items, let start):
            MediaCarouselView(service: session.service, images: items, start: start) { media = nil }
        case .video(let e):
            VideoPlayerView(streamServer: streamServer, entry: e) { media = nil }
        case .quicklook(let e):
            QuickLookView(service: session.service, entry: e) { media = nil }
        }
    }
}
