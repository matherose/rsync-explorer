/**
 * AppDelegate.swift
 * Application entry point. Creates the main window and sets up the menu bar.
 */

import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    var mainWindowController: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        mainWindowController = MainWindowController()
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.orderFrontRegardless()
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    private func setupMenuBar() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu(title: "rsync-explorer")
        appItem.submenu?.addItem(NSMenuItem(title: "About rsync-explorer",
                                            action: nil, keyEquivalent: ""))
        appItem.submenu?.addItem(NSMenuItem.separator())
        appItem.submenu?.addItem(NSMenuItem(title: "Hide rsync-explorer",
                                            action: #selector(NSApplication.hide(_:)),
                                            keyEquivalent: "h"))
        appItem.submenu?.addItem(NSMenuItem(title: "Quit rsync-explorer",
                                            action: #selector(NSApplication.terminate(_:)),
                                            keyEquivalent: "q"))
        mainMenu.addItem(appItem)

        // View menu
        let viewItem = NSMenuItem()
        viewItem.submenu = NSMenu(title: "View")
        let timelineMenuItem = NSMenuItem(
            title: "Show Timeline",
            action: #selector(MainWindowController.toggleTimeline(_:)),
            keyEquivalent: "t")
        timelineMenuItem.target = nil   // routed via the responder chain
        viewItem.submenu?.addItem(timelineMenuItem)
        viewItem.submenu?.addItem(NSMenuItem.separator())
        viewItem.submenu?.addItem(NSMenuItem(title: "Enter Full Screen",
                                             action: #selector(NSWindow.toggleFullScreen(_:)),
                                             keyEquivalent: "f"))
        mainMenu.addItem(viewItem)

        // Window menu
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(NSMenuItem(title: "Minimize",
                                               action: #selector(NSWindow.performMiniaturize(_:)),
                                               keyEquivalent: "m"))
        windowItem.submenu?.addItem(NSMenuItem(title: "Zoom",
                                               action: #selector(NSWindow.performZoom(_:)),
                                               keyEquivalent: ""))
        NSApp.windowsMenu = windowItem.submenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }
}

// swiftc CLI entry point — @main attribute doesn't work reliably from CLI
// We use a custom main() that manually sets up the NSApplication
@_silgen_name("main")
public func main(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32 {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
    return 0
}
