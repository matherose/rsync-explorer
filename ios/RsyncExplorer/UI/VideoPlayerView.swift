import SwiftUI

struct VideoPlayerView: View {
    let service: SFTPService
    let entry: RemoteEntry
    var onClose: () -> Void

    @State private var localURL: URL?
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let localURL {
                VLCPlayerContainer(url: localURL).ignoresSafeArea()
            } else if let error {
                Text(error).foregroundStyle(.white).font(.callout).padding()
            } else {
                VStack(spacing: 12) {
                    ProgressView(value: progress).tint(.white).frame(width: 200)
                    Text("Downloading… \(Int(progress * 100))%").foregroundStyle(.white)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.9)).padding()
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            localURL = try await FileCache.shared.fetch(entry, via: service) { p in
                Task { @MainActor in progress = p }
            }
        } catch {
            self.error = "Couldn't load video:\n\(error)"
        }
    }
}
