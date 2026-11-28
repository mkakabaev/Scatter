import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    /// Dedicated clear field editor for `SearchNSTextField` (avoids default glass chrome).
    private var searchFieldEditor: NSTextView?
    private var store: AppStore!
    private var storeCancellables = Set<AnyCancellable>()
    /// True while the launcher is key/front. Cleared on resign only after the current
    /// run-loop turn so status-item clicks (which resign key before the action) still
    /// see “was front” and can hide instead of re-raising.
    private var mainWindowIsFrontmost = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // macOS 26+ injects SF Symbols onto standard menu actions (Settings → gear, Quit, …).
        // Opt out so Quick Access stays text-only; clearing `image` after the fact still flashes.
        UserDefaults.standard.set(false, forKey: "NSMenuEnableActionImages")

        store = AppStore()
        HotkeyManager.toggleHandler = { [weak self] in
            self?.toggleOrRaiseMainWindow()
        }
        HotkeyManager.install()
        setupStatusItem()
        setupMainWindow()
        observeStore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.flushPendingSave()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        store.showMainWindow()
        return true
    }

    /// Menu-bar app: never open an untitled/placeholder window (the empty SwiftUI Settings stub).
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    /// App menu / ⌘, — routed from `AppMain` so the SwiftUI Settings scene stays closed.
    func openSettingsFromMenu() {
        store.requestSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Do not steal focus back while Launch Services is bringing up another app —
        // that bounce-then-deactivate cycle can quit some utilities (e.g. measurement tools).
        guard !store.isLaunchingExternalApp else { return }
        raiseMainWindowIfVisible()
    }

    /// If the launcher is already on screen, make it key/front. No-op when hidden.
    /// Does not call `NSApp.activate` — main window is a nonactivating panel.
    /// Skips while Settings is up so activate-for-settings does not bury Settings under the panel.
    private func raiseMainWindowIfVisible() {
        guard !store.isLaunchingExternalApp else { return }
        if let settings = settingsWindow, settings.isVisible { return }
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
    /// `moveToActiveSpace` on the panel migrates it to the current desktop Space when ordered front.
    private func bringMainWindowToFront() {
        guard let window = mainWindow else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
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
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
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
        ItemOpener.open(item, settings: store.state.settings, keepWindowOpen: true, store: store)
    }

    @objc private func showWindow() {
        let alreadyVisible = store.isMainWindowVisible && (mainWindow?.isVisible ?? false)
        store.showMainWindow()
        // Bridge only runs on a visibility transition; relocate when already open.
        if alreadyVisible {
            presentMainWindow()
        }
    }

    @objc private func openSettings() {
        store.requestSettings()
    }

    private func setupMainWindow() {
        let root = MainWindowView()
            .environmentObject(store)
        let hosting = NSHostingController(rootView: root)
        let window = LauncherWindow(
            contentRect: NSRect(x: 0, y: 0, width: store.state.settings.windowWidth, height: store.state.settings.windowHeight),
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
        // Appear on the Space the user is currently viewing (not the Space where the panel last lived).
        window.collectionBehavior.insert(.moveToActiveSpace)
        // Clear AppKit chrome so SwiftUI can paint a translucent preference color once
        // (avoid double-compositing the same alpha on window + content).
        hosting.view.wantsLayer = true
        hosting.view.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.view.focusRingType = .none
        window.contentViewController = hosting
        window.delegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        // Close only — keep .resizable for edge resize, but hide minimize/zoom (agent app).
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.onCancel = { [weak self] in
            self?.store.handleMainWindowCancel()
        }
        applyRestoredContentSize(to: window)
        centerOnActiveScreen(window)
        // Create/attach the shared field editor while the panel is still hidden so the
        // first type-to-search focus does not flash frosted glass chrome.
        FieldEditorStyle.warm(in: window)
        mainWindow = window
    }

    private func applyRestoredContentSize(to window: NSWindow) {
        let width = max(640, store.state.settings.windowWidth)
        let height = max(400, store.state.settings.windowHeight)
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

    private func showSettingsWindow() {
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(store)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 512, height: 572),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Settings"
            window.contentViewController = hosting
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        guard let window = settingsWindow else { return }
        window.layoutIfNeeded()
        if let content = window.contentViewController?.view {
            let fitting = content.fittingSize
            if fitting.width > 0, fitting.height > 0 {
                window.setContentSize(fitting)
            }
        }
        centerOnActiveScreen(window)
        // Sit above the nonactivating main panel (same level is not enough after orderFrontRegardless).
        if let main = mainWindow {
            window.level = max(main.level + 1, window.level)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let main = mainWindow, main.isVisible {
            window.order(.above, relativeTo: main.windowNumber)
        }
    }

    private func observeStore() {
        storeCancellables.removeAll()

        store.$isMainWindowVisible
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] visible in
                guard let self else { return }
                if visible {
                    self.mainWindow?.backgroundColor = .clear
                    self.presentMainWindow()
                } else {
                    self.mainWindow?.orderOut(nil)
                }
            }
            .store(in: &storeCancellables)

        store.$settingsRequestID
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.showSettingsWindow()
            }
            .store(in: &storeCancellables)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard sender === mainWindow, client is SearchNSTextField else { return nil }
        if searchFieldEditor == nil {
            let editor = NSTextView(frame: .zero)
            FieldEditorStyle.apply(editor)
            searchFieldEditor = editor
        } else if let editor = searchFieldEditor {
            FieldEditorStyle.apply(editor)
        }
        return searchFieldEditor
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === mainWindow {
            store.hideMainWindow()
        }
        // Settings stays allocated (`isReleasedWhenClosed = false`); next request re-fronts it.
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
        store.updateSettings {
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
