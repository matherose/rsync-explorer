import SwiftUI

/// A seek bar modeled on the native iOS video scrubber: a thin rounded track with a knob
/// that *swells* while you scrub. Unlike `Slider` (which only responds to grabbing the
/// thumb), a tap OR drag anywhere on the bar seeks to that point — so you never have to
/// chase the moving knob — and the whole 44pt-tall row is the touch target. The drag is
/// `highPriorityGesture` so it wins against the surrounding paging `TabView` instead of
/// being mistaken for a page swipe (the old plain `.gesture` let the pager steal it,
/// which is why the bar felt impossible to grab).
struct Scrubber: View {
    let fraction: Double                        // 0...1, current position to display
    var onEditingChanged: (Bool) -> Void = { _ in }
    var onSeek: (Double) -> Void                // continuous during a drag, and on tap

    @State private var dragging = false
    private let idleTrack: CGFloat = 6
    private let activeTrack: CGFloat = 11
    private let idleKnob: CGFloat = 16
    private let activeKnob: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = CGFloat(max(0, min(1, fraction)))
            let track = dragging ? activeTrack : idleTrack
            let knob = dragging ? activeKnob : idleKnob
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3)).frame(height: track)
                Capsule().fill(.white).frame(width: max(track, w * f), height: track)
                Circle().fill(.white).frame(width: knob, height: knob)
                    .shadow(radius: 3)
                    // Keep the knob fully inside the track instead of hanging off the ends.
                    .offset(x: min(max(0, w * f - knob / 2), w - knob))
            }
            .frame(maxHeight: .infinity)        // center the bar in the tall touch row
            .contentShape(Rectangle())          // the whole 44pt height is grabbable
            .highPriorityGesture(               // beat the carousel's horizontal paging swipe
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
            .animation(.easeOut(duration: 0.18), value: dragging)
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
