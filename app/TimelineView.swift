/**
 * TimelineView.swift
 * Custom dual-handle range selector for snapshot timeline navigation.
 */

import Cocoa

protocol TimelineViewDelegate: AnyObject {
    func timelineRangeChanged(from: Int, to: Int)
}

class TimelineView: NSView {

    weak var delegate: TimelineViewDelegate?

    var snapshots: [Snapshot] = [] {
        didSet { needsDisplay = true }
    }

    var fromIdx: Int = 0 {
        didSet { needsDisplay = true }
    }

    var toIdx: Int = 0 {
        didSet { needsDisplay = true }
    }

    private let trackHeight: CGFloat = 6
    private let handleWidth: CGFloat = 14
    private let handleHeight: CGFloat = 24
    private var draggingHandle: HandleType? = nil
    private var dragStartX: CGFloat = 0
    private var dragStartIdx: Int = 0

    private enum HandleType {
        case from, to
    }

    override var intrinsicContentSize: NSSize {
        return NSSize(width: NSView.noIntrinsicMetric, height: 44)
    }

    // MARK: - Layout helpers

    private var trackRect: NSRect {
        let margin: CGFloat = 20
        return NSRect(x: margin, y: (bounds.height - trackHeight) / 2,
                       width: bounds.width - 2 * margin, height: trackHeight)
    }

    private func xForIndex(_ idx: Int) -> CGFloat {
        guard snapshots.count > 1 else { return trackRect.midX }
        let fraction = CGFloat(idx) / CGFloat(snapshots.count - 1)
        return trackRect.minX + fraction * trackRect.width
    }

    private func indexForX(_ x: CGFloat) -> Int {
        guard snapshots.count > 1 else { return 0 }
        let fraction = (x - trackRect.minX) / trackRect.width
        let idx = Int(round(fraction * CGFloat(snapshots.count - 1)))
        return max(0, min(snapshots.count - 1, idx))
    }

    private func handleRect(for idx: Int) -> NSRect {
        let cx = xForIndex(idx)
        return NSRect(x: cx - handleWidth / 2,
                       y: (bounds.height - handleHeight) / 2,
                       width: handleWidth, height: handleHeight)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard !snapshots.isEmpty else {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let str = NSAttributedString(string: "No snapshots", attributes: attrs)
            str.draw(at: NSPoint(x: 10, y: (bounds.height - str.size().height) / 2))
            return
        }

        // Track background
        let trackPath = NSBezierPath(roundedRect: trackRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
        NSColor.separatorColor.setFill()
        trackPath.fill()

        // Active range fill
        let rangeRect = NSRect(x: xForIndex(fromIdx),
                                y: trackRect.minY,
                                width: xForIndex(toIdx) - xForIndex(fromIdx),
                                height: trackHeight)
        if rangeRect.width > 0 {
            let rangePath = NSBezierPath(roundedRect: rangeRect, xRadius: trackHeight / 2, yRadius: trackHeight / 2)
            NSColor.controlAccentColor.setFill()
            rangePath.fill()
        }

        // Tick marks + date labels
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MM-dd"

        for i in 0..<snapshots.count {
            let x = xForIndex(i)

            // Tick
            let tick = NSRect(x: x - 0.5, y: trackRect.minY - 3, width: 1, height: 3)
            NSColor.tertiaryLabelColor.setFill()
            tick.fill()

            // Label (show every few to avoid crowding)
            let step = max(1, snapshots.count / 10)
            if i % step == 0 || i == snapshots.count - 1 {
                let label = dateFormatter.string(from: snapshots[i].dateEpoch)
                let str = NSAttributedString(string: label, attributes: labelAttrs)
                let strSize = str.size()
                str.draw(at: NSPoint(x: x - strSize.width / 2,
                                     y: trackRect.minY - 16))
            }
        }

        // Handles
        drawHandle(handleRect(for: fromIdx), isFrom: true)
        drawHandle(handleRect(for: toIdx), isFrom: false)
    }

    private func drawHandle(_ rect: NSRect, isFrom: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        NSColor.controlAccentColor.setFill()
        path.fill()
        NSColor.white.setStroke()
        path.lineWidth = 1
        path.stroke()

        // Grip lines
        let cx = rect.midX
        for offset in [-3, 0, 3] {
            let y = rect.midY + CGFloat(offset)
            let line = NSRect(x: cx - 2, y: y - 0.5, width: 4, height: 1)
            NSColor.white.withAlphaComponent(0.6).setFill()
            line.fill()
        }
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if handleRect(for: fromIdx).contains(point) {
            draggingHandle = .from
            dragStartX = point.x
            dragStartIdx = fromIdx
        } else if handleRect(for: toIdx).contains(point) {
            draggingHandle = .to
            dragStartX = point.x
            dragStartIdx = toIdx
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let handle = draggingHandle else { return }
        let point = convert(event.locationInWindow, from: nil)
        let newIdx = indexForX(point.x)

        switch handle {
        case .from:
            fromIdx = min(newIdx, toIdx)  // from must be <= to
        case .to:
            toIdx = max(newIdx, fromIdx)  // to must be >= from
        }
    }

    override func mouseUp(with event: NSEvent) {
        if draggingHandle != nil {
            delegate?.timelineRangeChanged(from: fromIdx, to: toIdx)
        }
        draggingHandle = nil
    }
}
