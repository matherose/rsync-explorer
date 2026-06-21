import SwiftUI
import QuickLook

struct QuickLookView: View {
    let service: SFTPService
    let entry: RemoteEntry
    var onClose: () -> Void

    @State private var localURL: URL?
    @State private var progress: Double = 0
    @State private var error: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(.systemBackground).ignoresSafeArea()
            if let localURL {
                QuickLookPreview(url: localURL).ignoresSafeArea()
            } else if let error {
                Text(error).foregroundStyle(.red).font(.callout).padding()
            } else {
                ProgressView(value: progress) {
                    Text("Downloading… \(Int(progress * 100))%")
                }
                .frame(width: 220)
            }
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.largeTitle).padding()
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
            self.error = "Couldn't load file:\n\(error)"
        }
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController,
                               previewItemAt index: Int) -> QLPreviewItem {
            url as NSURL
        }
    }
}
