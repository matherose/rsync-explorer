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

    @State private var currentID: Int?
    // Flipped off while the scrubber is being dragged so the horizontal page scroll can't
    // steal the drag out from under it. `.scrollDisabled` on a real ScrollView is reliable.
    @State private var pagingEnabled = true

    init(service: SFTPService, streamServer: LocalStreamServer, items: [RemoteEntry],
         start: RemoteEntry, onClose: @escaping () -> Void) {
        self.service = service
        self.streamServer = streamServer
        self.items = items
        self.start = start
        self.onClose = onClose
        _currentID = State(initialValue: items.firstIndex(of: start) ?? 0)
    }

    private var currentIndex: Int { currentID ?? 0 }

    var body: some View {
        // A horizontal paging ScrollView (iOS 17) instead of a paging TabView, whose
        // PageTabViewStyle nudges content a few px as it settles ("the bump"). Pages are
        // pinned to the full screen for edge-to-edge media; the bottom safe-area inset is
        // handed to the player so its control bar still sits above the home indicator.
        GeometryReader { proxy in
            let screen = CGSize(
                width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom)
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, entry in
                            // Only materialize the active page and its immediate neighbors,
                            // so a folder with hundreds of items doesn't spin up a VLC
                            // player per page; off-window pages collapse to a placeholder.
                            Group {
                                if abs(i - currentIndex) <= 1 {
                                    MediaPageView(entry: entry, isActive: i == currentIndex,
                                                  service: service, streamServer: streamServer,
                                                  pagingEnabled: $pagingEnabled,
                                                  safeBottom: proxy.safeAreaInsets.bottom)
                                } else {
                                    Color.black
                                }
                            }
                            .frame(width: screen.width, height: screen.height)
                            .id(i)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $currentID)
                .scrollIndicators(.hidden)
                .scrollDisabled(!pagingEnabled)
                .ignoresSafeArea()

                // Swipe down from the top to dismiss. Confined to a top strip so its drag
                // recognizer doesn't blanket the whole screen.
                dismissStrip

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.largeTitle).foregroundStyle(.white.opacity(0.9)).padding()
                }
                .accessibilityLabel("Close")
            }
        }
    }

    private var dismissStrip: some View {
        VStack {
            Color.clear
                .frame(maxWidth: .infinity).frame(height: 150)
                .contentShape(Rectangle())
                .simultaneousGesture(   // recognizes alongside controls; never blocks them
                    DragGesture(minimumDistance: 20).onEnded { v in
                        if v.translation.height > 120,
                           v.translation.height > abs(v.translation.width) {
                            onClose()
                        }
                    }
                )
            Spacer()
        }
        .ignoresSafeArea()
    }
}

private struct MediaPageView: View {
    let entry: RemoteEntry
    let isActive: Bool
    let service: SFTPService
    let streamServer: LocalStreamServer
    @Binding var pagingEnabled: Bool
    var safeBottom: CGFloat = 0

    var body: some View {
        switch entry.kind {
        case .image:
            ZoomableImageView(service: service, entry: entry, isActive: isActive)
        case .video, .audio:
            CarouselPlayerView(entry: entry, isActive: isActive, service: service,
                               streamServer: streamServer, pagingEnabled: $pagingEnabled,
                               safeBottom: safeBottom)
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
                        .accessibilityLabel(entry.name)
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
        // Load as soon as this page enters the carousel's render window (the active page
        // and its two neighbors). Preloading the neighbors means the next image is already
        // decoded when you swipe to it, instead of flashing a spinner then popping in.
        .task { await load() }
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
