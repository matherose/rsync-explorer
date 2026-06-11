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
    /// In-memory whole-backup index (engine-owned; freed on rebuild/close).
    private var index: OpaquePointer?

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
    private let themeToggleButton = NSButton()
    private let keyAppearance = "rsyncx.appearance" // "system" | "light" | "dark"
    private var timelineHeightConstraint: NSLayoutConstraint!
    private let keyTimelineVisible = "rsyncx.timeline.visible"
    private var timelineVisible: Bool {
        get { UserDefaults.standard.bool(forKey: keyTimelineVisible) } // default false
        set { UserDefaults.standard.set(newValue, forKey: keyTimelineVisible) }
    }

    // Navigation stack
    private var pathStack: [String] = []
    private var indexGeneration = 0

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
        // Resolve constraint-based layout so the split view has its real width
        // before positioning the divider; otherwise the divider stays at 0 and
        // the sidebar collapses behind the file list.
        window?.layoutIfNeeded()
        splitView.setPosition(180, ofDividerAt: 0)
    }

    func windowWillClose(_ notification: Notification) {
        // Invalidate any in-flight build so its completion frees its own index.
        indexGeneration += 1
        if let idx = index { EngineBridge.freeIndex(idx); index = nil }
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
        breadcrumbLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        breadcrumbLabel.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(breadcrumbLabel)

        toolbar.addSubview(searchField)
        toolbar.addSubview(timelineToggleButton)

        themeToggleButton.bezelStyle = .inline
        themeToggleButton.target = self
        themeToggleButton.action = #selector(toggleTheme(_:))
        themeToggleButton.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(themeToggleButton)

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
            breadcrumbLabel.trailingAnchor.constraint(lessThanOrEqualTo: themeToggleButton.leadingAnchor, constant: -8),

            themeToggleButton.trailingAnchor.constraint(equalTo: columnsButton.leadingAnchor, constant: -8),
            themeToggleButton.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            themeToggleButton.widthAnchor.constraint(equalToConstant: 28),

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
            // The file list reports a leaf name (e.g. "src") relative to the
            // current directory, so append it to form the full path rather than
            // replacing (which would jump to a wrong root-level path).
            self.currentPath = self.currentPath.isEmpty
                ? relPath
                : self.currentPath + "/" + relPath
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
        applyStoredAppearance()

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
                self.rebuildIndex()
            }
        }
    }

    // MARK: - Index building

    private func rebuildIndex() {
        guard let source = currentSource, !snapshots.isEmpty else { return }
        if let old = index { EngineBridge.freeIndex(old); index = nil }
        indexGeneration += 1
        let generation = indexGeneration

        let snaps = snapshots
        let from = timelineVisible ? fromIdx : 0
        let to   = timelineVisible ? toIdx   : max(0, snaps.count - 1)
        statusBar.startLoading()
        statusBar.update(files: 0, deleted: 0, modified: 0, new: 0, unchanged: 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let idx = EngineBridge.buildIndex(source: source, snapshots: snaps,
                                              fromIdx: from, toIdx: to) { _, _, files in
                DispatchQueue.main.async {
                    guard let self = self, generation == self.indexGeneration else { return }
                    self.statusBar.update(files: files, deleted: 0, modified: 0,
                                          new: 0, unchanged: 0)
                }
            }
            DispatchQueue.main.async {
                guard let self = self, generation == self.indexGeneration else {
                    // Window closed or a newer rebuild superseded this one.
                    if let idx = idx { EngineBridge.freeIndex(idx) }
                    return
                }
                self.statusBar.stopLoading()
                guard let idx = idx else {
                    self.showAlert(title: "Indexing Failed",
                                   message: "Couldn't index \(source.name).")
                    return
                }
                self.index = idx
                self.scanCurrentDir()
                self.expandCurrentTree()
            }
        }
    }

    // MARK: - Directory scanning

    private func scanCurrentDir() {
        updateBreadcrumb()
        guard let idx = index else { return }
        let files = EngineBridge.indexChildren(idx, relPath: currentPath)
        fileListVC.updateFiles(files)
        let deleted   = files.filter { $0.classification == .deleted }.count
        let delNew    = files.filter { $0.classification == .delNew }.count
        let modified  = files.filter { $0.classification == .modified }.count
        let newFiles  = files.filter { $0.classification == .isNew }.count
        let unchanged = files.filter { $0.classification == .unchanged }.count
        statusBar.update(files: files.count, deleted: deleted + delNew,
                         modified: modified, new: newFiles, unchanged: unchanged)
    }

    private func expandCurrentTree() {
        guard let idx = index else { return }
        let dirs = EngineBridge.indexDirs(idx, relPath: currentPath)
        sidebarVC.updateEntries(dirs, currentPath: currentPath)
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
        rebuildIndex()
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
            rebuildIndex()
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
        guard !query.isEmpty, let idx = index else { return }
        let results = EngineBridge.indexSearch(idx, query: query)
        fileListVC.updateFiles(results)
        let deleted   = results.filter { $0.classification == .deleted }.count
        let delNew    = results.filter { $0.classification == .delNew }.count
        let modified  = results.filter { $0.classification == .modified }.count
        let newFiles  = results.filter { $0.classification == .isNew }.count
        let unchanged = results.filter { $0.classification == .unchanged }.count
        statusBar.update(files: results.count, deleted: deleted + delNew,
                         modified: modified, new: newFiles, unchanged: unchanged)
    }

    // MARK: - FileListDownloadDelegate

    func scpArguments(for entry: FileEntry, to destination: URL) -> [String]? {
        guard let source = currentSource, source.type == .remote else { return nil }
        let remotePath = entry.lastRealPath
        // Defense for legacy (non-SFTP) scp: reject control chars that could
        // break out on a remote shell. Modern macOS scp uses SFTP (path is literal).
        guard !remotePath.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) else { return nil }
        let remoteSpec = "\(source.user)@\(source.host):\(remotePath)"
        return ["-i", source.sshKey,
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=no",
                remoteSpec,
                destination.path]
    }

    func downloadFile(_ entry: FileEntry, to localURL: URL) {
        guard currentSource?.type == .remote else {
            try? FileManager.default.copyItem(at: URL(fileURLWithPath: entry.lastRealPath),
                                                to: localURL)
            return
        }
        guard let args = scpArguments(for: entry, to: localURL) else { return }
        statusBar.startLoading()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
            process.arguments = args
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

    // MARK: - Theme

    private func storedAppearance() -> String {
        return UserDefaults.standard.string(forKey: keyAppearance) ?? "system"
    }

    private func applyStoredAppearance() {
        switch storedAppearance() {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil   // follow the system
        }
        updateThemeButtonImage()
    }

    private func updateThemeButtonImage() {
        let dark: Bool
        switch storedAppearance() {
        case "light": dark = false
        case "dark":  dark = true
        default:      dark = effectiveAppearanceIsDark() // system: effective is the right source
        }
        let symbol = dark ? "sun.max.fill" : "moon.fill"
        themeToggleButton.image = NSImage(systemSymbolName: symbol,
                                          accessibilityDescription: "Toggle Theme")
    }

    private func effectiveAppearanceIsDark() -> Bool {
        let name = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        return name == .darkAqua
    }

    @objc func toggleTheme(_ sender: Any?) {
        // First use overrides "system" with an explicit choice; thereafter flips.
        let nextDark = !effectiveAppearanceIsDark()
        UserDefaults.standard.set(nextDark ? "dark" : "light", forKey: keyAppearance)
        applyStoredAppearance()
    }
}
