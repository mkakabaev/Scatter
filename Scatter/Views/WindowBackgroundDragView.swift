import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Empty-area hit target: click runs `onClick`; drag past a small threshold moves the window.
/// Uses AppKit so `performDrag(with:)` receives the original mouse-down event.
/// Finder / browser drops are handled here too — SwiftUI `.onDrop` on an `NSViewRepresentable`
/// often shows the green-plus cursor but never completes `NSItemProvider` loads for regular files.
struct WindowBackgroundDragView: NSViewRepresentable {
    struct MenuItem {
        var title: String
        var isSeparator: Bool = false
        /// Evaluated when the menu opens; `nil` means always enabled. Ignored for separators/submenus.
        var isEnabled: ((CGPoint) -> Bool)? = nil
        /// Canvas/local point where the context menu was opened (flipped view coords).
        var action: (CGPoint) -> Void = { _ in }
        /// When non-nil, this entry is a submenu titled `title`.
        var children: [MenuItem]? = nil

        static func separator() -> MenuItem {
            MenuItem(title: "", isSeparator: true)
        }

        static func submenu(title: String, children: [MenuItem]) -> MenuItem {
            MenuItem(title: title, children: children)
        }

        init(
            title: String,
            isEnabled: ((CGPoint) -> Bool)? = nil,
            action: @escaping (CGPoint) -> Void
        ) {
            self.title = title
            self.isSeparator = false
            self.isEnabled = isEnabled
            self.action = action
            self.children = nil
        }

        private init(title: String, isSeparator: Bool) {
            self.title = title
            self.isSeparator = isSeparator
            self.isEnabled = nil
            self.action = { _ in }
            self.children = nil
        }

        private init(title: String, children: [MenuItem]) {
            self.title = title
            self.isSeparator = false
            self.isEnabled = nil
            self.action = { _ in }
            self.children = children
        }
    }

    struct ItemFrame {
        var id: UUID
        var frame: CGRect
    }

    var onClick: () -> Void
    /// Right-click menu for empty canvas / sidebar padding (AppKit — reliable over NSView).
    var contextMenuItems: [MenuItem] = []
    /// Called when the empty-area context menu is about to appear.
    var onContextMenuOpen: (() -> Void)? = nil
    /// Dropped file/http URLs and the drop point in flipped view coordinates.
    var onURLsDropped: (([URL], CGPoint) -> Void)? = nil
    /// Canvas item frames in this view’s flipped coordinates (for context-menu highlight).
    var itemFrames: [ItemFrame] = []
    /// Right-click on an item frame → transient highlight (canvas only).
    var onItemContextMenuHighlight: ((UUID) -> Void)? = nil
    var onItemContextMenuHighlightClear: (() -> Void)? = nil

    func makeNSView(context: Context) -> WindowBackgroundDragNSView {
        let view = WindowBackgroundDragNSView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: WindowBackgroundDragNSView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: WindowBackgroundDragNSView) {
        view.onClick = onClick
        view.contextMenuItems = contextMenuItems
        view.onContextMenuOpen = onContextMenuOpen
        view.onURLsDropped = onURLsDropped
        view.itemFrames = itemFrames
        view.onItemContextMenuHighlight = onItemContextMenuHighlight
        view.onItemContextMenuHighlightClear = onItemContextMenuHighlightClear
        view.updateHighlightMonitoring()
    }
}

final class WindowBackgroundDragNSView: NSView {
    var onClick: (() -> Void)?
    var contextMenuItems: [WindowBackgroundDragView.MenuItem] = []
    var onContextMenuOpen: (() -> Void)?
    var onURLsDropped: (([URL], CGPoint) -> Void)?
    var itemFrames: [WindowBackgroundDragView.ItemFrame] = []
    var onItemContextMenuHighlight: ((UUID) -> Void)?
    var onItemContextMenuHighlightClear: (() -> Void)?

    private var lastMenuPoint: CGPoint = .zero
    /// Retains leaf-item targets for the open context menu.
    private var menuHandlers: [ContextMenuHandler] = []

    private var rightMouseMonitor: Any?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?
    /// Item highlight is live; clear only after a matching `didBeginTracking` → `didEndTracking`.
    private var itemHighlightMenuTracking = false
    private var itemHighlightPendingMenu = false

    /// Match item-drag threshold in `FreeformCanvasView`.
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // File URLs + generic URLs (browser link pasteboards).
        registerForDraggedTypes([
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType(UTType.url.identifier),
            NSPasteboard.PasteboardType(UTType.fileURL.identifier),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        tearDownHighlightMonitoring()
    }

    func updateHighlightMonitoring() {
        if onItemContextMenuHighlight != nil {
            installHighlightMonitoring()
        } else {
            tearDownHighlightMonitoring()
        }
    }

    private func installHighlightMonitoring() {
        guard rightMouseMonitor == nil else { return }
        rightMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            self?.handleRightMouseDownForItemHighlight(event)
            return event
        }
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMenuDidBeginTracking()
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleMenuDidEndTracking()
        }
    }

    private func tearDownHighlightMonitoring() {
        if let rightMouseMonitor {
            NSEvent.removeMonitor(rightMouseMonitor)
        }
        rightMouseMonitor = nil
        if let menuBeginObserver {
            NotificationCenter.default.removeObserver(menuBeginObserver)
        }
        menuBeginObserver = nil
        if let menuEndObserver {
            NotificationCenter.default.removeObserver(menuEndObserver)
        }
        menuEndObserver = nil
        itemHighlightMenuTracking = false
        itemHighlightPendingMenu = false
    }

    private func handleRightMouseDownForItemHighlight(_ event: NSEvent) {
        guard onItemContextMenuHighlight != nil else { return }
        guard let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }

        var hit: UUID?
        for item in itemFrames where item.frame.contains(point) {
            hit = item.id
        }
        guard let hit else { return }

        itemHighlightPendingMenu = true
        itemHighlightMenuTracking = false
        onItemContextMenuHighlight?(hit)
    }

    private func handleMenuDidBeginTracking() {
        guard itemHighlightPendingMenu else { return }
        itemHighlightPendingMenu = false
        itemHighlightMenuTracking = true
    }

    private func handleMenuDidEndTracking() {
        guard itemHighlightMenuTracking else { return }
        itemHighlightMenuTracking = false
        onItemContextMenuHighlightClear?()
    }

    func clearItemHighlightSession() {
        itemHighlightPendingMenu = false
        itemHighlightMenuTracking = false
        onItemContextMenuHighlightClear?()
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !contextMenuItems.isEmpty else { return nil }
        lastMenuPoint = convert(event.locationInWindow, from: nil)
        // Item tiles sit above this view in SwiftUI, but AppKit may still ask us for a menu.
        // Defer to the item’s SwiftUI `.contextMenu` and do not clear the item highlight.
        if itemFrames.contains(where: { $0.frame.contains(lastMenuPoint) }) {
            return nil
        }
        menuHandlers.removeAll(keepingCapacity: true)
        clearItemHighlightSession()
        onContextMenuOpen?()
        return buildMenu(from: contextMenuItems, point: lastMenuPoint)
    }

    private func buildMenu(
        from items: [WindowBackgroundDragView.MenuItem],
        point: CGPoint
    ) -> NSMenu {
        let menu = NSMenu()
        // Without this, AppKit re-enables items that have a valid target/action.
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            if let children = item.children {
                let mi = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                mi.submenu = buildMenu(from: children, point: point)
                // Disable the parent when every leaf under it is disabled.
                mi.isEnabled = hasEnabledLeaf(in: children, point: point)
                menu.addItem(mi)
                continue
            }
            let enabled = item.isEnabled?(point) ?? true
            let handler = ContextMenuHandler(point: point, isEnabled: enabled, run: item.action)
            menuHandlers.append(handler)
            let mi = NSMenuItem(
                title: item.title,
                action: #selector(ContextMenuHandler.invoke(_:)),
                keyEquivalent: ""
            )
            mi.target = handler
            mi.isEnabled = enabled
            menu.addItem(mi)
        }
        return menu
    }

    private func hasEnabledLeaf(
        in items: [WindowBackgroundDragView.MenuItem],
        point: CGPoint
    ) -> Bool {
        for item in items {
            if item.isSeparator { continue }
            if let children = item.children {
                if hasEnabledLeaf(in: children, point: point) { return true }
                continue
            }
            if item.isEnabled?(point) ?? true { return true }
        }
        return false
    }
}

/// Leaf context-menu action target. Kept alive by `WindowBackgroundDragNSView.menuHandlers`.
private final class ContextMenuHandler: NSObject {
    private let point: CGPoint
    private let isEnabled: Bool
    private let run: (CGPoint) -> Void

    init(point: CGPoint, isEnabled: Bool, run: @escaping (CGPoint) -> Void) {
        self.point = point
        self.isEnabled = isEnabled
        self.run = run
    }

    @objc func invoke(_ sender: Any?) {
        guard isEnabled else { return }
        run(point)
    }
}

extension WindowBackgroundDragNSView {
    // MARK: - Dragging destination (Finder / browser)

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let onURLsDropped else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let urls = ItemOpener.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped(urls, point)
        return true
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        guard onURLsDropped != nil else { return false }
        return !ItemOpener.urls(from: sender.draggingPasteboard).isEmpty
            || ItemOpener.draggedWebLink() != nil
    }

    // MARK: - Window drag

    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window else { return }
        let start = event.locationInWindow
        var didMoveWindow = false

        // Left-click ends any stuck item-menu highlight (e.g. menu begin never arrived).
        clearItemHighlightSession()

        window.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp],
            timeout: NSEvent.foreverDuration,
            mode: .eventTracking
        ) { tracked, stop in
            guard let tracked else { return }
            if tracked.type == .leftMouseUp {
                if !didMoveWindow {
                    DispatchQueue.main.async { self.onClick?() }
                }
                stop.pointee = true
                return
            }
            let dx = tracked.locationInWindow.x - start.x
            let dy = tracked.locationInWindow.y - start.y
            guard !didMoveWindow, hypot(dx, dy) >= self.dragThreshold else { return }
            didMoveWindow = true
            // Original mouse-down required; AppKit continues the move from here.
            window.performDrag(with: event)
            stop.pointee = true
        }
    }
}
