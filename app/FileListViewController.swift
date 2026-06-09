/**
 * FileListViewController.swift
 * Finder-like file list: clean rows, file-type icons, leading status dots,
 * right-click context menu, Quick Look with remote download, double-click nav.
 */

import Cocoa
import Quartz

protocol FileListDownloadDelegate: AnyObject {
    func downloadFile(_ entry: FileEntry, to localURL: URL)
    /// scp argument vector (everything after the `scp` executable) to copy
    /// `entry` to `destination`, or nil if the source is local / not permitted.
    func scpArguments(for entry: FileEntry, to destination: URL) -> [String]?
}

class FileListViewController: NSViewController,
                                NSTableViewDataSource,
                                NSTableViewDelegate,
                                QLPreviewPanelDataSource,
                                QLPreviewPanelDelegate,
                                QuickLookPreviewDelegate,
                                NSMenuDelegate {

    private var tableView: QuickLookTableView!
    private var scrollView: NSScrollView!
    private var columnConfig = ColumnConfig()
    private var files: [FileEntry] = []
    private var sortedFiles: [FileEntry] = []
    private var sortColumn: String = "path"
    private var sortAscending: Bool = true

    var onNavigateDir: ((String) -> Void)?
    weak var downloadDelegate: FileListDownloadDelegate?

    // MARK: - Lifecycle

    override func loadView() {
        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.autoresizingMask = [.width, .height]
        scrollView.borderType = .noBorder

        tableView = QuickLookTableView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.style = .plain
        tableView.rowHeight = 20
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.backgroundColor = .controlBackgroundColor
        tableView.allowsColumnResizing = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnSelection = false
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(doubleClickRow)
        tableView.target = self
        tableView.previewDelegate = self
        tableView.autoresizingMask = [.width, .height]

        let headerGesture = NSClickGestureRecognizer(target: self,
                                                       action: #selector(headerRightClick))
        headerGesture.buttonMask = 0x2
        tableView.headerView?.addGestureRecognizer(headerGesture)

        setupContextMenu()
        rebuildColumns()

        scrollView.documentView = tableView
        view = scrollView
    }

    // MARK: - Column management

    private func rebuildColumns() {
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }

        for def in columnConfig.visibleColumns() {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(def.id))
            col.title = def.title
            col.minWidth = def.minWidth
            col.resizingMask = [.autoresizingMask, .userResizingMask]
            tableView.addTableColumn(col)
        }
    }

    @objc private func headerRightClick() { showColumnMenu() }

    func showColumnMenu() {
        let menu = NSMenu()
        for def in columnConfig.allColumnsOrdered() {
            let item = NSMenuItem(title: def.title, action: #selector(toggleColumn(_:)),
                                   keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(def.id)
            item.state = columnConfig.isVisible(def.id) ? .on : .off
            menu.addItem(item)
        }
        NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent!, for: tableView.headerView!)
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let id = sender.identifier?.rawValue else { return }
        columnConfig.toggle(id)
        rebuildColumns()
        tableView.reloadData()
    }

    // MARK: - Data

    func updateFiles(_ files: [FileEntry]) {
        self.files = files
        applySorting()
        tableView.reloadData()
        tableView.sizeToFit()
    }

    // MARK: - Sorting

    private func applySorting() {
        sortedFiles = files.sorted { a, b in
            let result: ComparisonResult
            switch sortColumn {
            case "class":       result = compareClass(a: a, b: b)
            case "perm":        result = permString(a.mode).compare(permString(b.mode))
            case "user":        result = a.user.localizedCaseInsensitiveCompare(b.user)
            case "group":       result = a.group.localizedCaseInsensitiveCompare(b.group)
            case "size":        result = a.size < b.size ? .orderedAscending :
                                       a.size > b.size ? .orderedDescending : .orderedSame
            case "mtime":       result = a.mtime < b.mtime ? .orderedAscending :
                                       a.mtime > b.mtime ? .orderedDescending : .orderedSame
            case "firstBackup": result = a.firstBackup < b.firstBackup ? .orderedAscending :
                                       a.firstBackup > b.firstBackup ? .orderedDescending : .orderedSame
            case "lastBackup":  result = a.lastBackup < b.lastBackup ? .orderedAscending :
                                       a.lastBackup > b.lastBackup ? .orderedDescending : .orderedSame
            case "deletedIn":   result = compareOptDate(a.deletedIn, b.deletedIn)
            case "nlink":       result = a.nlink < b.nlink ? .orderedAscending :
                                       a.nlink > b.nlink ? .orderedDescending : .orderedSame
            default:            result = a.relPath.localizedCaseInsensitiveCompare(b.relPath)
            }
            return sortAscending ? result == .orderedAscending : result == .orderedDescending
        }
    }

    private func compareClass(a: FileEntry, b: FileEntry) -> ComparisonResult {
        let order: [FileClass] = [.deleted, .delNew, .modified, .isNew, .unchanged]
        let ai = order.firstIndex(of: a.classification) ?? 99
        let bi = order.firstIndex(of: b.classification) ?? 99
        return ai < bi ? .orderedAscending : ai > bi ? .orderedDescending : .orderedSame
    }

    private func compareOptDate(_ a: Date?, _ b: Date?) -> ComparisonResult {
        guard let a = a else { return b == nil ? .orderedSame : .orderedAscending }
        guard let b = b else { return .orderedDescending }
        return a < b ? .orderedAscending : a > b ? .orderedDescending : .orderedSame
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { sortedFiles.count }

    // MARK: - NSTableViewDelegate — Finder-like rows

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard row < sortedFiles.count, let colId = tableColumn?.identifier.rawValue else { return nil }
        let file = sortedFiles[row]
        let cell = NSTableCellView()

        if colId == "path" {
            if let dot = statusDot(for: file.classification) {
                cell.addSubview(dot)
            }

            let icon = NSImageView()
            icon.image = iconForFile(file)
            icon.imageScaling = .scaleProportionallyDown
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)

            let label = NSTextField(labelWithString: displayName(file))
            label.font = NSFont.systemFont(ofSize: 13)
            label.lineBreakMode = .byTruncatingMiddle
            label.textColor = (file.classification == .deleted) ? .systemRed : .labelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)

            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 18),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),

                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        } else {
            let label = NSTextField(labelWithString: valueForColumn(file, colId))
            label.font = NSFont.systemFont(ofSize: 11)
            label.lineBreakMode = .byTruncatingTail
            label.alignment = (colId == "size" || colId == "nlink") ? .right : .left
            label.textColor = colId == "class" ? badgeColor(for: file.classification) : .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)

            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        return LifecycleRow()
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        let colId = tableColumn.identifier.rawValue
        if sortColumn == colId { sortAscending.toggle() }
        else { sortColumn = colId; sortAscending = true }
        applySorting()
        tableView.reloadData()
    }

    // MARK: - File icon (like Finder)

    /// Small leading dot: green = new, amber = modified/recreated, none otherwise.
    private func statusDot(for cls: FileClass) -> NSView? {
        let color: NSColor
        switch cls {
        case .isNew:             color = .systemGreen
        case .modified, .delNew: color = .systemOrange
        default:                 return nil   // deleted shows as red name; unchanged shows nothing
        }
        let dot = NSView(frame: NSRect(x: 6, y: 6, width: 8, height: 8))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 4
        return dot
    }

    private func iconForFile(_ file: FileEntry) -> NSImage? {
        if file.isDir {
            return NSImage(systemSymbolName: "folder.fill",
                           accessibilityDescription: "Folder")
        }
        let ext = URL(fileURLWithPath: file.relPath).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "tiff", "bmp", "heic", "webp":
            return NSImage(systemSymbolName: "photo", accessibilityDescription: "Image")
        case "mp4", "mov", "avi", "mkv", "m4v", "wmv":
            return NSImage(systemSymbolName: "film", accessibilityDescription: "Video")
        case "mp3", "wav", "aac", "flac", "m4a", "ogg":
            return NSImage(systemSymbolName: "music.note", accessibilityDescription: "Audio")
        case "pdf":
            return NSImage(systemSymbolName: "doc.fill", accessibilityDescription: "PDF")
        case "doc", "docx", "odt", "rtf", "txt", "md":
            return NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Document")
        case "xls", "xlsx", "csv":
            return NSImage(systemSymbolName: "tablecells", accessibilityDescription: "Spreadsheet")
        case "zip", "tar", "gz", "bz2", "xz", "7z", "rar":
            return NSImage(systemSymbolName: "doc.zipper", accessibilityDescription: "Archive")
        case "app", "dmg":
            return NSImage(systemSymbolName: "app", accessibilityDescription: "App")
        default:
            return NSImage(systemSymbolName: "doc", accessibilityDescription: "File")
        }
    }

    /// Display just the filename, not the full relative path.
    private func displayName(_ file: FileEntry) -> String {
        return URL(fileURLWithPath: file.relPath).lastPathComponent
    }

    // MARK: - Class badge & colors

    private func badgeColor(for cls: FileClass) -> NSColor {
        switch cls {
        case .deleted:   return NSColor.systemRed
        case .delNew:    return NSColor.systemOrange
        case .modified:  return NSColor.systemBlue
        case .isNew:     return NSColor.systemGreen
        case .unchanged: return NSColor.secondaryLabelColor
        }
    }

    // MARK: - Cell values

    private func valueForColumn(_ file: FileEntry, _ colId: String) -> String {
        switch colId {
        case "class":       return classLabel(file.classification)
        case "perm":        return permString(file.mode)
        case "user":        return file.user
        case "group":       return file.group
        case "size":        return sizeString(file.size)
        case "mtime":       return formatDate(file.mtime)
        case "firstBackup": return formatDate(file.firstBackup)
        case "lastBackup":  return formatDate(file.lastBackup)
        case "deletedIn":   return file.deletedIn.map { formatDate($0) } ?? ""
        case "nlink":       return "\(file.nlink)"
        case "path":        return displayName(file)
        default:            return ""
        }
    }

    private func classLabel(_ cls: FileClass) -> String {
        switch cls {
        case .unchanged: return "—"
        case .modified:  return "Mod"
        case .isNew:     return "New"
        case .deleted:   return "Del"
        case .delNew:    return "D→N"
        }
    }

    private func formatDate(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateStyle = .short
        fmt.timeStyle = .short
        return fmt.string(from: date)
    }

    private func permString(_ mode: UInt32) -> String {
        let m = mode
        let s0 = (m & UInt32(S_IRUSR) != 0) ? "r" : "-"
        let s1 = (m & UInt32(S_IWUSR) != 0) ? "w" : "-"
        let s2 = (m & UInt32(S_IXUSR) != 0) ? "x" : "-"
        let s3 = (m & UInt32(S_IRGRP) != 0) ? "r" : "-"
        let s4 = (m & UInt32(S_IWGRP) != 0) ? "w" : "-"
        let s5 = (m & UInt32(S_IXGRP) != 0) ? "x" : "-"
        let s6 = (m & UInt32(S_IROTH) != 0) ? "r" : "-"
        let s7 = (m & UInt32(S_IWOTH) != 0) ? "w" : "-"
        let s8 = (m & UInt32(S_IXOTH) != 0) ? "x" : "-"
        let prefix = (m & UInt32(S_IFDIR) != 0) ? "d" : "-"
        return prefix + s0+s1+s2+s3+s4+s5+s6+s7+s8
    }

    private func sizeString(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    // MARK: - Double-click

    @objc private func doubleClickRow() {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedFiles.count else { return }
        let file = sortedFiles[row]
        if file.isDir {
            onNavigateDir?(file.relPath)
        } else {
            openFileInPreview(file)
        }
    }

    // MARK: - Context menu

    private func setupContextMenu() {
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = tableView.clickedRow
        guard row >= 0, row < sortedFiles.count else { return }

        menu.addItem(NSMenuItem(title: "Open",
                                  action: #selector(contextOpen), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quick Look",
                                  action: #selector(contextQuickLook), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Download to…",
                                  action: #selector(contextDownload), keyEquivalent: ""))
    }

    @objc private func contextOpen() {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedFiles.count else { return }
        openFileInPreview(sortedFiles[row])
    }

    @objc private func contextQuickLook() { togglePreviewPanel() }

    @objc private func contextDownload() {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedFiles.count else { return }
        let file = sortedFiles[row]
        let panel = NSSavePanel()
        panel.title = "Download \"\(displayName(file))\""
        panel.nameFieldStringValue = URL(fileURLWithPath: file.relPath).lastPathComponent
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: view.window!) { response in
            guard response == .OK, let destURL = panel.url else { return }
            self.downloadDelegate?.downloadFile(file, to: destURL)
        }
    }

    // MARK: - File opening

    private func openFileInPreview(_ file: FileEntry) {
        guard !file.isDir else { return }
        downloadToTempAndOpen(file: file)
    }

    private func downloadToTempAndOpen(file: FileEntry) {
        let fileName = URL(fileURLWithPath: file.relPath).lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsync-explorer-preview", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: tempFile)

        guard let args = downloadDelegate?.scpArguments(for: file, to: tempFile) else {
            // Local source (or not permitted): open the file directly.
            NSWorkspace.shared.open(URL(fileURLWithPath: file.lastRealPath))
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationStatus == 0 && FileManager.default.fileExists(atPath: tempFile.path) {
                    DispatchQueue.main.async { NSWorkspace.shared.open(tempFile) }
                }
            } catch {}
        }
    }

    // MARK: - Quick Look

    func togglePreviewPanel() {
        if let panel = QLPreviewPanel.shared() {
            if panel.isVisible { panel.orderOut(nil) }
            else { panel.makeKeyAndOrderFront(nil) }
        }
    }

    func spaceKeyPressed() {
        prepareQuickLookForSelectedFile { [weak self] in
            self?.togglePreviewPanel()
        }
    }

    func selectedFileURL() -> URL? {
        let row = tableView.selectedRow
        guard row >= 0, row < sortedFiles.count else { return nil }
        let file = sortedFiles[row]
        let fileName = URL(fileURLWithPath: file.relPath).lastPathComponent
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsync-explorer-preview/\(fileName)")
        if FileManager.default.fileExists(atPath: tempFile.path) { return tempFile }
        return URL(fileURLWithPath: file.lastRealPath)
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.delegate = self
        panel.dataSource = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {}

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }

    func previewPanel(_ panel: QLPreviewPanel!,
                      previewItemAt index: Int) -> (any QLPreviewItem)! {
        return selectedFileURL() as? NSURL
    }

    func previewPanel(_ panel: QLPreviewPanel!,
                      sourceFrameOnScreenFor item: (any QLPreviewItem)!) -> NSRect {
        let row = tableView.selectedRow
        guard row >= 0 else { return .zero }
        var rect = tableView.frameOfCell(atColumn: 0, row: row)
        rect = tableView.convert(rect, to: nil)
        return tableView.window?.convertToScreen(rect) ?? .zero
    }

    func prepareQuickLookForSelectedFile(completion: @escaping () -> Void) {
        let row = tableView.selectedRow
        guard row >= 0, row < sortedFiles.count else { completion(); return }
        let file = sortedFiles[row]
        if file.isDir { completion(); return }

        let fileName = URL(fileURLWithPath: file.relPath).lastPathComponent
        let tempFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsync-explorer-preview/\(fileName)")
        if FileManager.default.fileExists(atPath: tempFile.path) { completion(); return }

        guard let args = downloadDelegate?.scpArguments(for: file, to: tempFile) else { completion(); return }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run(); process.waitUntilExit() } catch {}
            DispatchQueue.main.async { completion() }
        }
    }
}
