import SwiftUI

/// Full-screen swipeable carousel over all media (images, video, audio) in a folder.
/// No page dots. Close button top-right; swipe down from the top to dismiss.
/// Video/audio auto-play only on the active page.
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
                    // Only materialize the active page and its immediate neighbors, so a
                    // folder with hundreds of media items doesn't spin up a VLC player per
                    // page. Off-window pages collapse to a placeholder; leaving the window
                    // tears the player down (onDisappear) and frees its memory.
                    Group {
                        if abs(i - index) <= 1 {
                            MediaPageView(entry: entry, isActive: index == i,
                                          service: service, streamServer: streamServer)
                        } else {
                            Color.black
                        }
                    }
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
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { v in
                // Pull down from near the top to dismiss (avoids fighting lyrics scroll).
                if v.startLocation.y < 150,
                   v.translation.height > 150,
                   v.translation.height > abs(v.translation.width) {
                    onClose()
                }
            }
        )
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
            ZoomableImageView(service: service, entry: entry, isActive: isActive)
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
    var isActive: Bool = true
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
        // Load only once this page is the active one, so a folder of large photos
        // doesn't decode every image at once. Stays loaded after first activation.
        .task(id: isActive) { if isActive { await load() } }
    }

    private func load() async {
        guard image == nil else { return }
        do {
            let url = try await FileCache.shared.fetch(entry, via: service) { _ in }
            // Cap decode size so huge photos don't blow up memory, with headroom for zoom.
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageDownsampler.downsample(fileURL: url, maxPixel: 2800)
            }.value
            if let decoded { image = decoded } else { failed = true }
        } catch {
            failed = true
        }
    }
}
