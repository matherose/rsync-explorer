import SwiftUI

/// A video/audio page inside the media carousel. Auto-plays only while it's the
/// active page; pauses when swiped away. Video shows auto-hiding controls; audio
/// shows cover art, title/artist, synced .lrc lyrics, and a persistent control bar.
struct CarouselPlayerView: View {
    let entry: RemoteEntry
    let isActive: Bool
    let service: SFTPService
    let streamServer: LocalStreamServer

    @StateObject private var model = VLCPlayerModel()
    @State private var url: URL?
    @State private var lyrics: [LyricLine]?
    @State private var controlsVisible = true
    @State private var dragPosition: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var showLyrics = true

    private var isAudio: Bool { entry.kind == .audio }
    private var displayName: String { (entry.name as NSString).deletingPathExtension }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                VLCDrawableView(model: model, url: url, fetchMetadata: isAudio).ignoresSafeArea()
            } else if isActive {
                ProgressView().tint(.white)
            }

            if isAudio {
                audioOverlay
            } else {
                Color.clear.contentShape(Rectangle()).onTapGesture { toggleControls() }
                if controlsVisible { videoControls }
            }
        }
        .task(id: isActive) { await update() }
        .task { if isAudio { lyrics = await LyricsLoader.loadLRC(for: entry, via: service) } }
        .onDisappear { model.stop(); hideTask?.cancel() }
    }

    // MARK: Audio layout

    private var audioOverlay: some View {
        VStack(spacing: 12) {
            Group {
                if let art = model.artwork {
                    Image(uiImage: art).resizable().scaledToFit()
                } else {
                    Image(systemName: "music.note").font(.system(size: 70)).foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: 220, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.top, 36)

            Text(displayName).foregroundStyle(.white).font(.headline)
                .multilineTextAlignment(.center).lineLimit(2).padding(.horizontal)
            if let artist = model.artist {
                Text(artist).foregroundStyle(.white.opacity(0.7)).font(.subheadline)
            }

            if let lyrics {
                Button { withAnimation { showLyrics.toggle() } } label: {
                    Label(showLyrics ? "Hide lyrics" : "Show lyrics", systemImage: "quote.bubble")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                }
                .padding(.top, 2)
                if showLyrics {
                    LyricsView(lines: lyrics, currentTimeMs: model.timeMs).frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }
            } else {
                Spacer()
            }

            controlBar.padding(.horizontal).padding(.bottom, 24)
        }
    }

    // MARK: Video layout

    private var videoControls: some View {
        VStack {
            Spacer()
            controlBar
                .padding()
                .background(LinearGradient(colors: [.clear, .black.opacity(0.6)],
                                           startPoint: .top, endPoint: .bottom))
        }
        .transition(.opacity)
    }

    // MARK: Shared control bar

    private var controlBar: some View {
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
    }

    private var positionBinding: Binding<Double> {
        Binding(get: { dragPosition ?? model.position }, set: { dragPosition = $0 })
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

    private func toggleControls() {
        withAnimation { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        guard !isAudio else { return }   // audio keeps controls visible
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
