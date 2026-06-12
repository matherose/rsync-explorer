/**
 * StatusBarController.swift
 * Displays file counts and a loading spinner in the status bar.
 */

import Cocoa

class StatusBarController: NSView {

    private let label = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)

        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = NSColor.secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.isHidden = true

        addSubview(label)
        addSubview(spinner)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(files: Int, deleted: Int, modified: Int, new: Int, unchanged: Int) {
        var parts: [String] = []
        parts.append("\(files) file\(files == 1 ? "" : "s")")
        if deleted > 0    { parts.append("\(deleted) deleted") }
        if modified > 0   { parts.append("\(modified) modified") }
        if new > 0        { parts.append("\(new) new") }
        if unchanged > 0  { parts.append("\(unchanged) unchanged") }
        label.stringValue = parts.joined(separator: " │ ")
    }

    func startLoading() {
        spinner.isHidden = false
        spinner.startAnimation(nil)
    }

    func stopLoading() {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
    }
}
