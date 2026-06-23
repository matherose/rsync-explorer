import SwiftUI

struct LyricsView: View {
    let lines: [LyricLine]
    let currentTimeMs: Int

    private var synced: Bool { lines.contains { $0.time != nil } }

    private var activeIndex: Int? {
        guard synced else { return nil }
        let t = Double(currentTimeMs) / 1000
        var idx: Int?
        for (i, line) in lines.enumerated() {
            if let lt = line.time, lt <= t { idx = i }
        }
        return idx
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(activeIndex == i ? .headline : .subheadline)
                            .foregroundStyle(lineColor(i))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(i)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: activeIndex) { _, idx in
                if let idx {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(idx, anchor: .center) }
                }
            }
        }
    }

    private func lineColor(_ i: Int) -> Color {
        guard synced else { return .white.opacity(0.85) }
        return activeIndex == i ? .white : .white.opacity(0.45)
    }
}
