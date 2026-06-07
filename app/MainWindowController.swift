/**
 * MainWindowController.swift
 * Finder-like layout: toolbar (back/search/source), timeline bar,
 * split view (sidebar | file list), status bar.
 */

import Cocoa

class MainWindowController: NSWindowController,
                              NSWindowDelegate,
                              SidebarDelegate,
                              TimelineViewDelegate,
                              NSSearchFieldDelegate,
                              NSMenuItemValidation,
                              FileListDownloadDelegate {

    private var sources: [Source] = []
    private var snapshots: [Snapshot] = []
    private var currentSource: Source?
    private var currentPath: String = ""
    private var fromIdx: Int = 0
    private var toIdx: Int = 0

    // Subviews
    private let splitView = NSSplitView()
    private let sidebarVC = SidebarViewController()
    private let fileListVC = FileListViewController()
    private let timelineView = TimelineView()
    private let statusBar = StatusBarController()
    private let searchField = NSSearchField()
    private let sourcePopup = NSPopUpButton()
    private let backButton = NSButton()
    private let timelineToggleButton = NSButton()
    private let breadcrumbLabel = NSTextField(labelWithString: "/")
    private let columnsButton = NSButton()
    private var timelineHeightConstraint: NSLayoutConstraint!
    private let keyTimelineVisible = "rsyncx.timeline.visible"
    private var timelineVisible: Bool {
        get { UserDefaults.standard.bool(forKey: keyTimelineVisible) } // default false
        set { UserDefaults.standard.set(newValue, forKey: keyTimelineVisible) }
    }

    // Navigation stack
    private var pathStack: [String] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "rsync-explorer"
        window.minSize = NSSize(width: 800, height: 500)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        buildUI()
        loadConfig()
        super.showWindow(sender)
        splitView.setPosition(180, ofDividerAt: 0)
    }

    // MARK: - UI construction

    private func buildUI() {
        guard let contentView = window?.contentView else { return }

        // Back button — simple chevron
        backButton.bezelStyle = .inline
        backButton.image = NSImage(systemSymbolName: "chevron.left",
                                    accessibilityDescription: "Back")
        backButton.imagePosition = .imageOnly
        backButton.toolTip = "Go back"
        backButton.target = self
        backButton.action = #selector(navigateBack)
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backButton.isBordered = false
        backButton.setButtonType(.momentaryChange)

        // Source popup — plain style
        sourcePopup.bezelStyle = .inline
        sourcePopup.translatesAutoresizingMaskIntoConstraints = false
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged)

        // Search — Finder-style rounded search field
        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchSubmitted)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        timelineToggleButton.bezelStyle = .inline
        timelineToggleButton.image = NSImage(systemSymbolName: "clock",
                                             accessibilityDescription: "Toggle Timeline")
        timelineToggleButton.target = self
        timelineToggleButton.action = #selector(toggleTimeline(_:))
        timelineToggleButton.translatesAutoresizingMaskIntoConstraints = false

        // Toolbar row
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        toolbar.addSubview(backButton)
        toolbar.addSubview(sourcePopup)

        breadcrumbLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        breadcrumbLabel.textColor = .secondaryLabelColor
        breadcrumbLabel.lineBreakMode = .byTruncatingHead
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(breadcrumbLabel)

        toolbar.addSubview(searchField)
        toolbar.addSubview(timelineToggleButton)

        columnsButton.bezelStyle = .inline
        columnsButton.image = NSImage(systemSymbolName: "slider.horizontal.3",
                                      accessibilityDescription: "Columns")
        columnsButton.target = self
        columnsButton.action = #selector(showColumnsMenu(_:))
        columnsButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(columnsButton)

        NSLayoutConstraint.activate([
            toolbar.heightAnchor.constraint(equalToConstant: 32),

            backButton.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 8),
            backButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 28),

            sourcePopup.leadingAnchor.constraint(equalTo: backButton.trailingAnchor, constant: 4),
            sourcePopup.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            breadcrumbLabel.leadingAnchor.constraint(equalTo: sourcePopup.trailingAnchor, constant: 10),
            breadcrumbLabel.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            columnsButton.trailingAnchor.constraint(equalTo: timelineToggleButton.leadingAnchor, constant: -8),
            columnsButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            columnsButton.widthAnchor.constraint(equalToConstant: 28),

            timelineToggleButton.trailingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: -8),
            timelineToggleButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            timelineToggleButton.widthAnchor.constraint(equalToConstant: 28),

            searchField.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            searchField.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
        ])

        // Timeline — compact, collapsible
        timelineView.delegate = self
        timelineView.translatesAutoresizingMaskIntoConstraints = false

        // Split view: sidebar | file list
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(sidebarVC.view)
        splitView.addArrangedSubview(fileListVC.view)
        sidebarVC.delegate = self

        fileListVC.onNavigateDir = { [weak self] relPath in
            guard let self = self else { return }
            self.pathStack.append(self.currentPath)
            self.currentPath = relPath
            self.scanCurrentDir()
            self.expandCurrentTree()
        }
        fileListVC.downloadDelegate = self

        // Status bar
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        // Add all views
        contentView.addSubview(toolbar)
        contentView.addSubview(timelineView)
        contentView.addSubview(splitView)
        contentView.addSubview(statusBar)

        timelineHeightConstraint = timelineView.heightAnchor.constraint(equalToConstant: 40)
        NSLayoutConstraint.activate([
            // Toolbar at top
            toolbar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            toolbar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 32),

            // Timeline below toolbar
            timelineView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            timelineView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            timelineView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            timelineHeightConstraint,

            // Split view fills remaining space
            splitView.topAnchor.constraint(equalTo: timelineView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            // Status bar at bottom
            statusBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 22),
        ])
        // Timeline hidden by default; user toggles it on.
        applyTimelineVisibility()

        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
    }

    // MARK: - Config & source

    private func loadConfig() {
        var configPath: String?
        if let bundlePath = Bundle.main.path(forResource: "config", ofType: "ini") {
            configPath = bundlePath
        } else if let execPath = Bundle.main.executablePath {
            let execDir = URL(fileURLWithPath: execPath).deletingLastPathComponent().path
            let candidate = execDir + "/config.ini"
            if FileManager.default.fileExists(atPath: candidate) {
                configPath = candidate
            }
        }
        if configPath == nil { configPath = "config.ini" }

        guard let path = configPath,
              let srcs = EngineBridge.parseConfig(at: path), !srcs.isEmpty else {
            showAlert(title: "Config Error",
                      message: "Could not parse config.ini.")
            return
        }
        sources = srcs
        sourcePopup.removeAllItems()
        for src in sources {
            sourcePopup.addItem(withTitle: "\(src.type == .local ? "📁" : "🌐") \(src.name)")
        }
        sourceChanged()
    }

    @objc private func sourceChanged() {
        let idx = sourcePopup.indexOfSelectedItem
        guard idx < sources.count else { return }
        currentSource = sources[idx]
        currentPath = ""
        pathStack.removeAll()
        discoverSnapshots()
    }

    // MARK: - Snapshot discovery

    private func discoverSnapshots() {
        guard let source = currentSource else { return }
        statusBar.startLoading()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snaps = EngineBridge.discover(source: source)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusBar.stopLoading()
                guard let snaps = snaps, !snaps.isEmpty else {
                    self.showAlert(title: "No Snapshots",
                                   message: "No snapshots found for \(source.name)")
                    return
                }
                self.snapshots = snaps
                self.timelineView.snapshots = snaps
                self.fromIdx = 0
                self.toIdx = snaps.count - 1
                self.timelineView.fromIdx = 0
                self.timelineView.toIdx = snaps.count - 1
                self.scanCurrentDir()
                self.expandCurrentTree()
            }
        }
    }

    // MARK: - Directory scanning

    private func scanCurrentDir() {
        updateBreadcrumb()
        guard let source = currentSource, !snapshots.isEmpty else { return }
        statusBar.startLoading()

        let path = currentPath
        let from = fromIdx
        let to = toIdx
        let snaps = snapshots

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let files = EngineBridge.scanDir(source: source, snapshots: snaps,
                                              relPath: path,
                                              fromIdx: from, toIdx: to)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusBar.stopLoading()
                guard let files = files else {
                    self.fileListVC.updateFiles([])
                    self.statusBar.update(files: 0, deleted: 0, modified: 0, new: 0, unchanged: 0)
                    return
                }
                self.fileListVC.updateFiles(files)
                let deleted   = files.filter { $0.classification == .deleted }.count
                let delNew    = files.filter { $0.classification == .delNew }.count
                let modified  = files.filter { $0.classification == .modified }.count
                let newFiles  = files.filter { $0.classification == .isNew }.count
                let unchanged = files.filter { $0.classification == .unchanged }.count
                self.statusBar.update(files: files.count,
                                       deleted: deleted + delNew,
                                       modified: modified,
                                       new: newFiles,
                                       unchanged: unchanged)
            }
        }
    }

    private func expandCurrentTree() {
        guard let source = currentSource, !snapshots.isEmpty else { return }
        let path = currentPath
        let from = fromIdx
        let to = toIdx
        let snaps = snapshots

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let dirs = EngineBridge.expandTree(source: source, snapshots: snaps,
                                                relPath: path,
                                                fromIdx: from, toIdx: to)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.sidebarVC.updateEntries(dirs ?? [], currentPath: path)
            }
        }
    }

    // MARK: - SidebarDelegate

    func sidebarDidSelect(path: String) {
        pathStack.append(currentPath)
        currentPath = path
        scanCurrentDir()
        expandCurrentTree()
    }

    // MARK: - Navigation

    @objc private func navigateBack() {
        guard !pathStack.isEmpty else { return }
        currentPath = pathStack.removeLast()
        scanCurrentDir()
        expandCurrentTree()
    }

    // MARK: - TimelineViewDelegate

    func timelineRangeChanged(from: Int, to: Int) {
        fromIdx = from
        toIdx = to
        scanCurrentDir()
        expandCurrentTree()
    }

    @objc func toggleTimeline(_ sender: Any?) {
        timelineVisible.toggle()
        applyTimelineVisibility()
        if !timelineVisible {
            // Reset to the full range so a hidden timeline means "all snapshots".
            fromIdx = 0
            toIdx = max(0, snapshots.count - 1)
            timelineView.fromIdx = fromIdx
            timelineView.toIdx = toIdx
            scanCurrentDir()
            expandCurrentTree()
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleTimeline(_:)) {
            menuItem.state = timelineVisible ? .on : .off
        }
        return true
    }

    private func applyTimelineVisibility() {
        timelineView.isHidden = !timelineVisible
        timelineHeightConstraint.constant = timelineVisible ? 40 : 0
        timelineToggleButton.state = timelineVisible ? .on : .off
    }

    // MARK: - Search

    @objc private func showColumnsMenu(_ sender: Any?) {
        fileListVC.showColumnMenu()
    }

    @objc private func searchSubmitted() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let source = currentSource else { return }
        statusBar.startLoading()

        let snaps = snapshots
        let from = timelineVisible ? fromIdx : 0
        let to   = timelineVisible ? toIdx   : max(0, snaps.count - 1)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = EngineBridge.search(source: source, snapshots: snaps,
                                               query: query,
                                               fromIdx: from, toIdx: to)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.statusBar.stopLoading()
                guard let results = results else {
                    self.fileListVC.updateFiles([])
                    return
                }
                self.fileListVC.updateFiles(results)
                let deleted   = results.filter { $0.classification == .deleted }.count
                let delNew    = results.filter { $0.classification == .delNew }.count
                let modified  = results.filter { $0.classification == .modified }.count
                let newFiles  = results.filter { $0.classification == .isNew }.count
                let unchanged = results.filter { $0.classification == .unchanged }.count
                self.statusBar.update(files: results.count,
                                       deleted: deleted + delNew,
                                       modified: modified,
                                       new: newFiles,
                                       unchanged: unchanged)
            }
        }
    }

    // MARK: - FileListDownloadDelegate

    func scpCommand(for entry: FileEntry) -> String? {
        guard let source = currentSource, source.type == .remote else { return nil }
        let remotePath = entry.lastRealPath
        let fileName = URL(fileURLWithPath: entry.relPath).lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsync-explorer-preview", isDirectory: true).path
        try? FileManager.default.createDirectory(atPath: tempDir,
                                                  withIntermediateDirectories: true)
        let destPath = tempDir + "/" + fileName
        return "scp -i \(source.sshKey) -o BatchMode=yes -o StrictHostKeyChecking=no "
             + "\(source.user)@\(source.host):\"\(remotePath)\" \"\(destPath)\""
    }

    func downloadFile(_ entry: FileEntry, to localURL: URL) {
        guard let source = currentSource, source.type == .remote else {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: entry.lastRealPath),
                                                to: localURL)
            return
        }
        let remotePath = entry.lastRealPath
        let scpCmd = "scp -i \(source.sshKey) -o BatchMode=yes -o StrictHostKeyChecking=no "
                   + "\(source.user)@\(source.host):\"\(remotePath)\" \"\(localURL.path)\""
        statusBar.startLoading()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", scpCmd]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                DispatchQueue.main.async {
                    self?.statusBar.stopLoading()
                    if process.terminationStatus != 0 {
                        self?.showAlert(title: "Download Failed",
                                        message: "SCP exited with code \(process.terminationStatus).")
                    } else {
                        NSWorkspace.shared.selectFile(localURL.path,
                                                      inFileViewerRootedAtPath: "")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self?.statusBar.stopLoading()
                    self?.showAlert(title: "Download Error", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Helpers

    private func updateBreadcrumb() {
        breadcrumbLabel.stringValue = currentPath.isEmpty ? "/" : "/" + currentPath
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
