import SwiftUI

struct VideoPlayerView: View {
    let streamServer: LocalStreamServer
    let entry: RemoteEntry
    var onClose: () -> Void

    @StateObject private var model = VLCPlayerModel()
    @State private var url: URL?
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var dragPosition: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            // Transparent tap layer: empty-area taps toggle the controls.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { toggleControls() }
            if controlsVisible { controls }
        }
        .statusBarHidden(true)
        .task {
            do { url = try await streamServer.streamURL(path: entry.path, size: entry.size) }
            catch { self.error = "Couldn't start stream:\n\(error)" }
        }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel(); model.stop() }
    }

    @ViewBuilder private var content: some View {
        if let url {
            VLCDrawableView(model: model, url: url).ignoresSafeArea()
        } else if let error {
            Text(error).foregroundStyle(.white).font(.callout).padding()
        } else {
            VStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Opening stream…").foregroundStyle(.white)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack {
                Text(entry.name).foregroundStyle(.white).font(.headline).lineLimit(1)
                Spacer()
                Button { model.stop(); onClose() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white)
                }
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.6), .clear],
                                       startPoint: .top, endPoint: .bottom))
            Spacer()
            HStack(spacing: 14) {
                Button { model.playPause(); scheduleHide() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).foregroundStyle(.white).frame(width: 30)
                }
                Text(timeString(model.timeMs)).foregroundStyle(.white).font(.caption).monospacedDigit()
                Slider(value: positionBinding, in: 0...1) { editing in
                    model.isSeeking = editing
                    if editing {
                        hideTask?.cancel()
                    } else {
                        if let d = dragPosition { model.seek(fraction: d) }
                        dragPosition = nil
                        scheduleHide()
                    }
                }
                .tint(.white)
                Text(timeString(model.lengthMs)).foregroundStyle(.white).font(.caption).monospacedDigit()
            }
            .padding()
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                       startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    private var positionBinding: Binding<Double> {
        Binding(get: { dragPosition ?? model.position }, set: { dragPosition = $0 })
    }

    private func toggleControls() {
        withAnimation { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled {
                await MainActor.run { withAnimation { controlsVisible = false } }
            }
        }
    }

    private func timeString(_ ms: Int) -> String {
        guard ms > 0 else { return "--:--" }
        let s = ms / 1000
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
