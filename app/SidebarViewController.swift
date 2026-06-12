/**
 * SidebarViewController.swift
 * NSOutlineView-based sidebar showing the directory tree with red badges
 * for directories that no longer exist in the latest snapshot.
 */

import Cocoa

protocol SidebarDelegate: AnyObject {
    func sidebarDidSelect(path: String)
}

class SidebarViewController: NSViewController,
                              NSOutlineViewDataSource,
                              NSOutlineViewDelegate {

    weak var delegate: SidebarDelegate?

    private var outlineView: NSOutlineView!
    private var entries: [DirEntry] = []
    private var currentPath: String = ""

    // MARK: - Lifecycle

    override func loadView() {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]

        outlineView = NSOutlineView()
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.headerView = nil
        outlineView.rowHeight = 24
        outlineView.selectionHighlightStyle = .regular
        outlineView.backgroundColor = NSColor.controlBackgroundColor
        outlineView.doubleAction = #selector(doubleClickItem)
        outlineView.target = self
        outlineView.autoresizingMask = [.width, .height]

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        outlineView.addTableColumn(col)
        outlineView.outlineTableColumn = col

        scrollView.documentView = outlineView
        view = scrollView
    }

    // MARK: - Data updates

    func updateEntries(_ entries: [DirEntry], currentPath: String) {
        self.entries = entries
        self.currentPath = currentPath
        outlineView.reloadData()
    }

    // MARK: - NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView,
                     numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            return entries.count
        }
        return 0  // flat list for now; nested expand is handled by navigation
    }

    func outlineView(_ outlineView: NSOutlineView,
                     isItemExpandable item: Any) -> Bool {
        return false  // flat list
    }

    func outlineView(_ outlineView: NSOutlineView,
                     child index: Int,
                     ofItem item: Any?) -> Any {
        return entries[index]
    }

    // MARK: - NSOutlineViewDelegate

    func outlineView(_ outlineView: NSOutlineView,
                     viewFor tableColumn: NSTableColumn?,
                     item: Any) -> NSView? {
        guard let entry = item as? DirEntry else { return nil }

        let cellId = NSUserInterfaceItemIdentifier("DirCell")
        let cell = outlineView.makeView(withIdentifier: cellId,
                                         owner: self) as? NSTableCellView
            ?? NSTableCellView()

        cell.identifier = cellId

        // Remove existing subviews
        cell.subviews.forEach { $0.removeFromSuperview() }

        // Folder icon
        let imageView = NSImageView()
        imageView.image = NSImage(systemSymbolName: "folder",
                                   accessibilityDescription: "Directory")
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        // Red badge for deleted dirs
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 4
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isHidden = entry.existsInLatest

        // Label
        let label = NSTextField(labelWithString: entry.name)
        label.font = NSFont.systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false

        if !entry.existsInLatest {
            label.textColor = NSColor.systemRed
        }

        cell.addSubview(imageView)
        cell.addSubview(badge)
        cell.addSubview(label)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),

            badge.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 2),
            badge.topAnchor.constraint(equalTo: imageView.topAnchor, constant: -1),
            badge.widthAnchor.constraint(equalToConstant: 8),
            badge.heightAnchor.constraint(equalToConstant: 8),

            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }

    /// Single-click selects but does NOT navigate.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        // Selection only — navigation happens on double-click
    }

    /// Double-click navigates into the selected directory.
    @objc private func doubleClickItem() {
        let row = outlineView.clickedRow
        guard row >= 0, row < entries.count else { return }
        let entry = entries[row]
        let path = currentPath.isEmpty ? entry.name : "\(currentPath)/\(entry.name)"
        delegate?.sidebarDidSelect(path: path)
    }
}
