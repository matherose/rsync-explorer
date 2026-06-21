import SwiftUI

struct MediaCarouselView: View {
    let service: SFTPService
    let images: [RemoteEntry]
    let start: RemoteEntry
    var onClose: () -> Void
    @State private var index = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.element.id) { i, entry in
                    ZoomableImageView(service: service, entry: entry).tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .automatic))
            .ignoresSafeArea()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.9)).padding()
            }
        }
        .onAppear { index = images.firstIndex(of: start) ?? 0 }
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
