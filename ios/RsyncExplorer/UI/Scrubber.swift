import SwiftUI

/// A full-width seek bar. Unlike `Slider` (which only responds to grabbing the thumb),
/// a tap OR drag anywhere on the bar seeks to that point — so you never have to chase
/// the moving thumb. The touch area is a full 44pt tall even though the track is thin.
struct Scrubber: View {
    let fraction: Double                        // 0...1, current position to display
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onSeek: (Double) -> Void                // continuous during a drag, and on tap

    @State private var dragging = false
    private let trackHeight: CGFloat = 4
    private let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = CGFloat(max(0, min(1, fraction)))
            let size = dragging ? thumb * 1.7 : thumb
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: trackHeight)
                Capsule().fill(.white).frame(width: max(0, w * f), height: trackHeight)
                Circle().fill(.white).frame(width: size, height: size)
                    .shadow(radius: 2)
                    .offset(x: w * f - size / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())          // the whole 44pt height is tappable
            .gesture(
                DragGesture(minimumDistance: 0)  // minimumDistance 0 => a tap is a 0-length drag
                    .onChanged { v in
                        if !dragging { dragging = true; onEditingChanged(true) }
                        onSeek(Self.fraction(forX: v.location.x, width: w))
                    }
                    .onEnded { v in
                        onSeek(Self.fraction(forX: v.location.x, width: w))
                        dragging = false; onEditingChanged(false)
                    }
            )
            .animation(.easeOut(duration: 0.15), value: dragging)
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityAdjustableAction { direction in
            let delta: Double = direction == .increment ? 0.05 : -0.05
            let f = max(0, min(1, fraction + delta))
            onEditingChanged(true); onSeek(f); onEditingChanged(false)
        }
    }

    /// Pure mapping from a touch x-offset to a 0...1 fraction, clamped to the bar ends.
    static func fraction(forX x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(max(0, min(width, x)) / width)
    }
}
