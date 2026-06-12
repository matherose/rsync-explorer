/**
 * QuickLookTableView.swift
 * NSTableView subclass that intercepts the Space key to toggle Quick Look.
 * For remote files, triggers a temp download before showing the preview.
 */

import Cocoa
import Quartz

class QuickLookTableView: NSTableView {

    weak var previewDelegate: QuickLookPreviewDelegate?

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers
        if key == " " {
            previewDelegate?.spaceKeyPressed()
        } else {
            super.keyDown(with: event)
        }
    }
}

protocol QuickLookPreviewDelegate: AnyObject {
    func togglePreviewPanel()
    func selectedFileURL() -> URL?
    /// Called when Space is pressed — downloads to temp if needed, then shows QL.
    func spaceKeyPressed()
}
