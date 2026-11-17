import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var preferencesWindow: NSWindow?
    private var store: AppStore!
    /// True while the launcher is key/front. Cleared on resign only after the current
    /// run-loop turn so status-item clicks (which resign key before the action) still
    /// see “was front” and can hide instead of re-raising.
    private var mainWindowIsFrontmost = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = AppStore()
        HotkeyManager.install(store: store)
        HotkeyManager.toggleHandler = { [weak self] in
            self?.toggleOrRaiseMainWindow()
        }
        setupStatusItem()
        setupMainWindow()
        observeStore()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store.showMainWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Do not steal focus back while Launch Services is bringing up another app —
        // that bounce-then-deactivate cycle can quit some utilities (e.g. measurement tools).
        guard !store.isLaunchingExternalApp else { return }
        raiseMainWindowIfVisible()
    }

    /// If the launcher is already on screen, make it key/front. No-op when hidden.
    /// Does not call `NSApp.activate` — main window is a nonactivating panel.
    /// Skips while Preferences is up so activate-for-prefs does not bury Preferences under the panel.
    private func raiseMainWindowIfVisible() {
        guard !store.isLaunchingExternalApp else { return }
        if let prefs = preferencesWindow, prefs.isVisible { return }
        guard store.isMainWindowVisible, let window = mainWindow, window.isVisible else { return }
        bringMainWindowToFront()
    }

    /// Hidden → show on mouse screen as key (without activating the app).
    /// Visible and front → hide. Visible but inactive/buried → raise only (no re-center).
    private func toggleOrRaiseMainWindow() {
        if store.isMainWindowVisible, let window = mainWindow, window.isVisible {
            if mainWindowIsFrontmost || window.isKeyWindow {
                store.hideMainWindow()
            } else {
                bringMainWindowToFront()
            }
        } else {
            store.showMainWindow()
        }
    }

    /// Size, center on the display under the mouse, then make key and order front (nonactivating).
    private func presentMainWindow() {
        guard let window = mainWindow else { return }
        applyRestoredContentSize(to: window)
        centerOnActiveScreen(window)
        bringMainWindowToFront()
    }

    /// Key + topmost without `NSApp.activate`, so the previous app keeps the menu bar.
    private func bringMainWindowToFront() {
        guard let window = mainWindow else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        mainWindowIsFrontmost = true
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: AppIdentity.displayName)
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else {
            toggleOrRaiseMainWindow()
            return
        }
        if event.type == .rightMouseUp {
            showQuickAccessMenu()
        } else {
            toggleOrRaiseMainWindow()
        }
    }

    private func showQuickAccessMenu() {
        let menu = NSMenu()
        for collection in store.sortedCollections {
            let submenu = NSMenu()
            if collection.items.isEmpty {
                let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                submenu.addItem(empty)
            } else {
                for item in collection.items.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
                    let mi = NSMenuItem(title: item.displayName, action: #selector(quickOpen(_:)), keyEquivalent: "")
                    mi.representedObject = item.id.uuidString
                    mi.target = self
                    submenu.addItem(mi)
                }
            }
            let parent = NSMenuItem(title: collection.name, action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Preferences…", action: #selector(openPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: "Show \(AppIdentity.displayName)", action: #selector(showWindow), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit \(AppIdentity.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func quickOpen(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let item = store.findItem(id) else { return }
        ItemOpener.open(item, preferences: store.state.preferences, keepWindowOpen: true, store: store)
    }

    @objc private func showWindow() {
        let alreadyVisible = store.isMainWindowVisible && (mainWindow?.isVisible ?? false)
        store.showMainWindow()
        // Bridge only runs on a visibility transition; relocate when already open.
        if alreadyVisible {
            presentMainWindow()
        }
    }

    @objc private func openPreferences() {
        store.requestPreferences()
    }

    private func setupMainWindow() {
        let root = MainWindowView()
            .environmentObject(store)
        let hosting = NSHostingController(rootView: root)
        let window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: store.state.preferences.windowWidth, height: store.state.preferences.windowHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = nil
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        // Clear AppKit chrome so SwiftUI can paint a translucent preference color once
        // (avoid double-compositing the same alpha on window + content).
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentViewController = hosting
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        // Close only — keep .resizable for edge resize, but hide minimize/zoom (agent app).
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.onCancel = { [weak self] in
            self?.store.hideMainWindow()
        }
        applyRestoredContentSize(to: window)
        centerOnActiveScreen(window)
        mainWindow = window
    }

    private func applyRestoredContentSize(to window: NSWindow) {
        let width = max(640, store.state.preferences.windowWidth)
        let height = max(400, store.state.preferences.windowHeight)
        window.setContentSize(NSSize(width: width, height: height))
    }

    /// Screen containing the mouse cursor (the display the user is working on).
    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func centerOnActiveScreen(_ window: NSWindow) {
        guard let screen = screenUnderMouse() else {
            window.center()
            return
        }
        let visible = screen.visibleFrame
        let frame = window.frame
        let x = visible.midX - frame.width / 2
        let y = visible.midY - frame.height / 2
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func showPreferencesWindow() {
        if preferencesWindow == nil {
            let root = PreferencesView()
                .environmentObject(store)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "\(AppIdentity.displayName) Preferences"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.delegate = self
            preferencesWindow = window
        }
        guard let window = preferencesWindow else { return }
        window.layoutIfNeeded()
        centerOnActiveScreen(window)
        // Sit above the nonactivating main panel (same level is not enough after orderFrontRegardless).
        if let main = mainWindow {
            window.level = max(main.level + 1, window.level)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let main = mainWindow, main.isVisible {
            window.order(.above, relativeTo: main.windowNumber)
        }
    }

    private func observeStore() {
        MainActorWindowBridge.shared.attach(
            store: store,
            showMain: { [weak self] in
                guard let self, let window = self.mainWindow else { return }
                window.backgroundColor = .clear
                self.presentMainWindow()
            },
            hideMain: { [weak self] in
                self?.mainWindow?.orderOut(nil)
            },
            showPrefs: { [weak self] in
                self?.showPreferencesWindow()
            }
        )
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow {
            store.hideMainWindow()
        }
        // Preferences stays allocated (`isReleasedWhenClosed = false`); next request re-fronts it.
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        mainWindowIsFrontmost = true
    }

    func windowDidResignKey(_ notification: Notification) {
        guard notification.object as? NSWindow === mainWindow else { return }
        store.clearSearch()
        // Defer clearing frontmost so a status-item click (resign then action in the
        // same turn) still toggles closed when the panel was already front.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.mainWindow?.isKeyWindow != true {
                self.mainWindowIsFrontmost = false
            }
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        let content = window.contentLayoutRect
        let width = max(window.contentView?.bounds.width ?? content.width, content.width)
        let height = max(window.contentView?.bounds.height ?? content.height, content.height)
        store.updatePreferences {
            $0.windowWidth = width
            $0.windowHeight = height
        }
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        windowDidResize(notification)
    }
}

/// Nonactivating launcher panel: can be key (type-to-search) without stealing the menu bar.
/// Swallows Esc / unhandled keys without AppKit’s alert beep.
final class LauncherWindow: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        // Do not call super — NSWindow.keyDown beeps for keys the first responder ignores.
    }
}

@MainActor
final class MainActorWindowBridge {
    static let shared = MainActorWindowBridge()
    private var task: Task<Void, Never>?
    private var lastVisible = false
    private var lastPrefsRequestID = 0

    func attach(store: AppStore, showMain: @escaping () -> Void, hideMain: @escaping () -> Void, showPrefs: @escaping () -> Void) {
        task?.cancel()
        lastPrefsRequestID = store.preferencesRequestID
        task = Task {
            while !Task.isCancelled {
                if store.isMainWindowVisible != lastVisible {
                    lastVisible = store.isMainWindowVisible
                    if lastVisible { showMain() } else { hideMain() }
                }
                if store.preferencesRequestID != lastPrefsRequestID {
                    lastPrefsRequestID = store.preferencesRequestID
                    showPrefs()
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}
