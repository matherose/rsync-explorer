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

    var body: some View {
        NavigationStack {
            DirectoryView(relPath: "", title: "Backup",
                          service: session.service,
                          snapshotRoots: session.snapshotRoots,
                          media: $media)
                .navigationDestination(for: DirRoute.self) { route in
                    DirectoryView(relPath: route.relPath, title: route.title,
                                  service: session.service,
                                  snapshotRoots: session.snapshotRoots,
                                  media: $media)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Disconnect") {
                            Task { await session.service.disconnect(); onDisconnect() }
                        }
                    }
                }
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
