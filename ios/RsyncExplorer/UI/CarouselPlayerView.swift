import SwiftUI

/// A video/audio page inside the media carousel. Auto-plays only while it's the
/// active page; pauses when swiped away. Shows an auto-hiding control bar.
struct CarouselPlayerView: View {
    let entry: RemoteEntry
    let isActive: Bool
    let streamServer: LocalStreamServer

    @StateObject private var model = VLCPlayerModel()
    @State private var url: URL?
    @State private var controlsVisible = true
    @State private var dragPosition: Double?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                VLCDrawableView(model: model, url: url).ignoresSafeArea()
            } else if isActive {
                ProgressView().tint(.white)
            }
            if entry.kind == .audio {
                VStack(spacing: 12) {
                    Image(systemName: "music.note").font(.system(size: 90)).foregroundStyle(.white.opacity(0.5))
                    Text(entry.name).foregroundStyle(.white).font(.callout).lineLimit(2).padding(.horizontal)
                }
            }
            Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }
            if controlsVisible { controlsBar }
        }
        .task(id: isActive) { await update() }
        .onDisappear { model.stop(); hideTask?.cancel() }
    }

    private func update() async {
        if isActive {
            if url == nil {
                url = try? await streamServer.streamURL(path: entry.path, size: entry.size)
            } else {
                model.player.play()
            }
            scheduleHide()
        } else {
            model.player.pause()
        }
    }

    private var controlsBar: some View {
        VStack {
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
        let s = ms / 1000, h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
