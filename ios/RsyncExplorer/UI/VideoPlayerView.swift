import SwiftUI

struct VideoPlayerView: View {
    let streamServer: LocalStreamServer
    let entry: RemoteEntry
    var onClose: () -> Void

    @State private var url: URL?
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let url {
                VLCPlayerContainer(url: url).ignoresSafeArea()
            } else if let error {
                Text(error).foregroundStyle(.white).font(.callout).padding()
            } else {
                VStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text("Opening stream…").foregroundStyle(.white)
                }
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.largeTitle).foregroundStyle(.white.opacity(0.9)).padding()
            }
        }
        .task {
            do {
                url = try await streamServer.streamURL(path: entry.path, size: entry.size)
            } catch {
                self.error = "Couldn't start stream:\n\(error)"
            }
        }
    }
}
