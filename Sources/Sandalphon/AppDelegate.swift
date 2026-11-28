import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let state = AppState()
    private var window: NSWindow?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()

        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.state.refresh()
            self?.updateStatusIcon()
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.state.controller.frontmostChanged(bundleID: app.bundleIdentifier, pid: app.processIdentifier)
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            self?.state.controller.mouseDown()
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, event.window !== self.state.panel.window { self.state.controller.mouseDown() }
            return event
        }
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))

        // First run, or permission missing: walk the user through setup instead of sitting silently in the menu bar.
        if !state.trusted || !UserDefaults.standard.bool(forKey: "welcomed") {
            UserDefaults.standard.set(true, forKey: "welcomed")
            showWindow(.overview)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.controller.saveIfIdle(force: true)
        Thread.sleep(forTimeInterval: 0.15)
    }

    /// Opening the app again (Finder, Spotlight, Dock) brings up its window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return false
    }

    /// sandalphon://general (or overview, setup), sandalphon://typing, sandalphon://apps, sandalphon://privacy
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text) else { return }
        let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        showWindow(Pane(rawValue: name == "settings" ? "typing" : (["permissions", "setup", "general"].contains(name) ? "overview" : name)))
    }

    // MARK: - Window

    private func showWindow(_ pane: Pane?) {
        if let pane { state.pane = pane }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Sandalphon"
            w.contentViewController = NSHostingController(rootView: MainView(state: state))
            w.setContentSize(NSSize(width: 760, height: 560))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            w.setFrameAutosaveName("SandalphonMain")
            window = w
        }
        // Show in the Dock and the app switcher while the window is open, like any other app.
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Menus

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let image = state.trusted ? MenuBarGlyph.image()
            : NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
        image?.isTemplate = true
        image?.accessibilityDescription = "Sandalphon: \(state.statusText)"
        button.image = image
        button.appearsDisabled = state.trusted && !state.settings.enabled
        button.toolTip = "Sandalphon: \(state.statusText)"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        @discardableResult
        func add(_ title: String, _ action: Selector?, key: String = "", on: Bool = false) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
            return item
        }
        let front = NSWorkspace.shared.frontmostApplication
        let frontID = front?.bundleIdentifier
        let offHere = frontID != Bundle.main.bundleIdentifier && state.settings.isExcluded(frontID)
        add(offHere && state.isActive ? "Sandalphon: Off in \(front?.localizedName ?? "this app")" : "Sandalphon: \(state.statusText)", nil)
        menu.addItem(.separator())
        if !state.trusted {
            add("Finish Setup…", #selector(openOverview))
        } else {
            add(state.settings.enabled ? "Pause Sandalphon" : "Resume Sandalphon", #selector(toggleEnabled))
        }
        menu.addItem(.separator())
        add("Autocorrect", #selector(toggleAutocorrect), on: state.settings.autocorrect)
        let modes = NSMenuItem(title: "Show Suggestions", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, mode) in [("Never", SuggestMode.never), ("Only with ⌥ Esc", .onDemand), ("While Typing", .whileTyping)] {
            let item = NSMenuItem(title: title, action: #selector(setMode(_:)), keyEquivalent: "")
            item.target = self
            item.tag = mode.rawValue
            item.state = state.settings.mode == mode ? .on : .off
            sub.addItem(item)
        }
        modes.submenu = sub
        menu.addItem(modes)
        if let front, let frontID, frontID != Bundle.main.bundleIdentifier {
            menu.addItem(.separator())
            add("Off in \(front.localizedName ?? frontID)", #selector(toggleExcluded), on: state.settings.isExcluded(frontID))
                .representedObject = frontID
        }
        menu.addItem(.separator())
        let recent = state.corrections.reversed()
        if !recent.isEmpty {
            let undo = NSMenuItem(title: "Recent Corrections", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for c in recent {
                let title = c.inPlace ? "\u{201C}\(c.replacement)\u{201D} \u{2190} \u{201C}\(c.original)\u{201D}"
                                      : "Don\u{2019}t correct \u{201C}\(c.original)\u{201D} again"
                let item = NSMenuItem(title: title, action: #selector(revertCorrection(_:)), keyEquivalent: "")
                item.target = self
                item.tag = c.id
                item.toolTip = c.inPlace ? "Change \u{201C}\(c.replacement)\u{201D} back to \u{201C}\(c.original)\u{201D} and stop correcting it"
                                         : "The text has moved on; this only stops the correction happening again"
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let hint = NSMenuItem(title: "Change the latest back anywhere with \u{2303}\u{2325}Z", action: nil, keyEquivalent: "")
            hint.isEnabled = false
            sub.addItem(hint)
            undo.submenu = sub
            menu.addItem(undo)
        }
        add("Settings…", #selector(openSettings), key: ",")
        if state.updater != nil { add("Check for Updates…", #selector(checkForUpdates)) }
        add("Star on GitHub…", #selector(openRepository))
        add("About Sandalphon", #selector(about))
        menu.addItem(.separator())
        add("Quit Sandalphon", #selector(quit), key: "q")
    }

    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ build: (NSMenu) -> Void) {
            let item = NSMenuItem()
            let menu = NSMenu(title: title)
            build(menu)
            item.submenu = menu
            main.addItem(item)
        }
        submenu("Sandalphon") { m in
            m.addItem(withTitle: "About Sandalphon", action: #selector(about), keyEquivalent: "").target = self
            m.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Hide Sandalphon", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
            m.addItem(withTitle: "Quit Sandalphon", action: #selector(quit), keyEquivalent: "q").target = self
        }
        submenu("Edit") { m in
            m.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
            m.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
            m.addItem(.separator())
            m.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            m.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            m.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            m.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        }
        submenu("Window") { m in
            m.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            m.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        }
        return main
    }

    @objc private func toggleEnabled() { state.update { $0.enabled.toggle() }; updateStatusIcon() }
    @objc private func toggleAutocorrect() { state.update { $0.autocorrect.toggle() } }
    @objc private func setMode(_ sender: NSMenuItem) {
        if let mode = SuggestMode(rawValue: sender.tag) { state.update { $0.mode = mode } }
    }

    /// Right-click › Services › Fix Typos with Sandalphon: replaces the selection with a corrected copy.
    @objc func fixTypos(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else { return }
        guard let fixed = state.controller.fixTypos(in: text) else {
            error.pointee = "Sandalphon could not fix this selection. It handles up to \(Controller.serviceLimit.formatted()) characters at a time." as NSString
            return
        }
        pboard.clearContents()
        pboard.setString(fixed, forType: .string)
    }
    @objc private func toggleExcluded(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { state.toggleExcluded(id) }
    }
    @objc private func checkForUpdates() { state.checkForUpdates() }
    @objc private func revertCorrection(_ item: NSMenuItem) { state.controller.revertFromMenu(item.tag) }
    @objc private func openRepository() { state.openRepository() }
    @objc private func openOverview() { showWindow(.overview) }
    @objc private func openSettings() { showWindow(state.trusted ? .typing : .overview) }
    @objc private func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Autocorrect and suggestions for everything you type on your Mac.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
    @objc private func quit() { NSApp.terminate(nil) }
}
