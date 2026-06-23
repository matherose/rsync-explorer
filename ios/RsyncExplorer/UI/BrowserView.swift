import SwiftUI

struct BrowserSession {
    let service: SFTPService
    let snapshotRoots: [String]   // newest -> oldest
}

enum MediaPresentation: Identifiable {
    case media(items: [RemoteEntry], start: RemoteEntry)
    case quicklook(RemoteEntry)

    var id: String {
        switch self {
        case .media(_, let s): return "media:" + s.path
        case .quicklook(let e): return "ql:" + e.path
        }
    }
}

struct BrowserView: View {
    let session: BrowserSession
    var onDisconnect: () -> Void

    @State private var media: MediaPresentation?
    @State private var share: ShareItem?
    @State private var showSettings = false
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
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showSettings = true } label: { Image(systemName: "gearshape") }
                    }
                }
                .fullScreenCover(item: $media) { mediaView($0) }
                .sheet(item: $share) { ActivityView(url: $0.url) }
                .sheet(isPresented: $showSettings) { SettingsView(onDisconnect: disconnect) }
        }
    }

    private func disconnect() {
        Task {
            await streamServer.shutdown()
            await session.service.disconnect()
            onDisconnect()
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
        case .media(let items, let start):
            MediaCarouselView(service: session.service, streamServer: streamServer,
                              items: items, start: start) { media = nil }
        case .quicklook(let e):
            QuickLookView(service: session.service, entry: e) { media = nil }
        }
    }
}
