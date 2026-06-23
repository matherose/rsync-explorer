import SwiftUI

/// Full-screen swipeable carousel over all media (images, video, audio) in a folder.
/// No page dots; one global close button. Video/audio auto-play only on the active page.
struct MediaCarouselView: View {
    let service: SFTPService
    let streamServer: LocalStreamServer
    let items: [RemoteEntry]
    let start: RemoteEntry
    var onClose: () -> Void

    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, entry in
                    MediaPageView(entry: entry, isActive: index == i,
                                  service: service, streamServer: streamServer)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.9)).padding()
            }
        }
        .onAppear { index = items.firstIndex(of: start) ?? 0 }
    }
}

private struct MediaPageView: View {
    let entry: RemoteEntry
    let isActive: Bool
    let service: SFTPService
    let streamServer: LocalStreamServer

    var body: some View {
        switch entry.kind {
        case .image:
            ZoomableImageView(service: service, entry: entry)
        case .video, .audio:
            CarouselPlayerView(entry: entry, isActive: isActive, service: service, streamServer: streamServer)
        default:
            Color.black
        }
    }
}

struct ZoomableImageView: View {
    let service: SFTPService
    let entry: RemoteEntry
    @State private var image: UIImage?
    @State private var failed = false
    @State private var scale: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, min($0, 5)) }
                                .onEnded { _ in if scale < 1.05 { withAnimation { scale = 1 } } }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation { scale = scale > 1 ? 1 : 2.5 }
                        }
                } else if failed {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task { await load() }
    }

    private func load() async {
        do {
            let url = try await FileCache.shared.fetch(entry, via: service) { _ in }
            if let img = UIImage(contentsOfFile: url.path) { image = img } else { failed = true }
        } catch {
            failed = true
        }
    }
}
