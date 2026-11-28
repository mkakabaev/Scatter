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
        /// App icon (or other) shown on the row via `NSMenuItem.image`.
        var image: NSImage? = nil
        /// When true, title uses the bold menu font (`attributedTitle`).
        var isBold: Bool = false
        /// When true, row shows a system checkbox (`NSMenuItem.state = .on`).
        var isOn: Bool = false

        static func separator() -> MenuItem {
            MenuItem(title: "", isSeparator: true)
        }

        static func submenu(title: String, children: [MenuItem]) -> MenuItem {
            MenuItem(title: title, children: children)
        }

        init(
            title: String,
            image: NSImage? = nil,
            isBold: Bool = false,
            isOn: Bool = false,
            isEnabled: ((CGPoint) -> Bool)? = nil,
            action: @escaping (CGPoint) -> Void
        ) {
            self.title = title
            self.isSeparator = false
            self.isEnabled = isEnabled
            self.action = action
            self.children = nil
            self.image = image
            self.isBold = isBold
            self.isOn = isOn
        }

        private init(title: String, isSeparator: Bool) {
            self.title = title
            self.isSeparator = isSeparator
            self.isEnabled = nil
            self.action = { _ in }
            self.children = nil
            self.image = nil
            self.isBold = false
            self.isOn = false
        }

        private init(title: String, children: [MenuItem]) {
            self.title = title
            self.isSeparator = false
            self.isEnabled = nil
            self.action = { _ in }
            self.children = children
            self.image = nil
            self.isBold = false
            self.isOn = false
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
    /// Pasteboard ingest result and drop point in flipped view coordinates.
    var onURLsDropped: ((PasteboardContents, CGPoint) -> Void)? = nil
    /// Canvas item frames in this view’s flipped coordinates (for context-menu highlight).
    var itemFrames: [ItemFrame] = []
    /// Right-click on an item frame → transient highlight (canvas only).
    var onItemContextMenuHighlight: ((UUID) -> Void)? = nil
    var onItemContextMenuHighlightClear: (() -> Void)? = nil
    /// When set, right-click on an item pops this AppKit menu (tiles sit above this view, so the
    /// local monitor consumes the event — SwiftUI `.contextMenu` cannot show `NSMenuItem.image`).
    var itemContextMenuItems: ((UUID) -> [MenuItem])? = nil

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
        // Canvas is the only surface that ingests Finder/URL drops; sidebar chrome does not.
        view.isCanvasDropTarget = onURLsDropped != nil
        view.itemFrames = itemFrames
        view.onItemContextMenuHighlight = onItemContextMenuHighlight
        view.onItemContextMenuHighlightClear = onItemContextMenuHighlightClear
        view.itemContextMenuItems = itemContextMenuItems
        view.updateHighlightMonitoring()
    }
}

final class WindowBackgroundDragNSView: NSView {
    /// Stable lookup for ⌘V placement — avoids ambiguous walks when multiple drag views exist.
    static let canvasDropIdentifier = NSUserInterfaceItemIdentifier("scatter.canvasDrop")

    var onClick: (() -> Void)?
    var contextMenuItems: [WindowBackgroundDragView.MenuItem] = []
    var onContextMenuOpen: (() -> Void)?
    var onURLsDropped: ((PasteboardContents, CGPoint) -> Void)?
    /// True when this view is the canvas drop surface (set from `onURLsDropped != nil`).
    var isCanvasDropTarget = false {
        didSet {
            identifier = isCanvasDropTarget ? Self.canvasDropIdentifier : nil
        }
    }
    var itemFrames: [WindowBackgroundDragView.ItemFrame] = []
    var onItemContextMenuHighlight: ((UUID) -> Void)?
    var onItemContextMenuHighlightClear: (() -> Void)?
    var itemContextMenuItems: ((UUID) -> [WindowBackgroundDragView.MenuItem])?

    private var lastMenuPoint: CGPoint = .zero
    /// Retains leaf-item targets for the open context menu.
    private var menuHandlers: [ContextMenuHandler] = []

    private var rightMouseMonitor: Any?

    /// Match item-drag threshold in `CanvasView`.
    private let dragThreshold: CGFloat = 4
    /// Cache `PasteboardIngest.read` across `draggingUpdated` for the same pasteboard generation.
    private var acceptCacheChangeCount: Int?
    private var acceptCacheResult = false

    override var isFlipped: Bool { true }

    /// Prefer the tagged canvas drop view over a generic `onURLsDropped` walk.
    static func canvasDropTarget(in root: NSView?) -> WindowBackgroundDragNSView? {
        guard let root else { return nil }
        if let drag = root as? WindowBackgroundDragNSView, drag.isCanvasDropTarget {
            return drag
        }
        for child in root.subviews {
            if let found = canvasDropTarget(in: child) { return found }
        }
        return nil
    }

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
            guard let self else { return event }
            // Tiles sit above this NSView, so `menu(for:)` is not asked for item hits. Consume the
            // event and pop an AppKit menu so browser rows can use `NSMenuItem.image` / bold titles.
            guard let itemID = self.itemIDAtEvent(event),
                  let builder = self.itemContextMenuItems else {
                return event
            }
            let items = builder(itemID)
            guard !items.isEmpty else { return event }

            self.onItemContextMenuHighlight?(itemID)
            let point = self.convert(event.locationInWindow, from: nil)
            self.lastMenuPoint = point
            self.menuHandlers.removeAll(keepingCapacity: true)
            let menu = self.buildMenu(from: items, point: point)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // `popUpContextMenu` runs until dismiss — clear highlight for this menu only.
                NSMenu.popUpContextMenu(menu, with: event, for: self)
                self.onItemContextMenuHighlightClear?()
            }
            return nil
        }
    }

    private func itemIDAtEvent(_ event: NSEvent) -> UUID? {
        guard let window, event.window === window else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return nil }
        return itemFrames.last(where: { $0.frame.contains(point) })?.id
    }

    private func tearDownHighlightMonitoring() {
        if let rightMouseMonitor {
            NSEvent.removeMonitor(rightMouseMonitor)
        }
        rightMouseMonitor = nil
    }

    func clearItemHighlightSession() {
        onItemContextMenuHighlightClear?()
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !contextMenuItems.isEmpty else { return nil }
        lastMenuPoint = convert(event.locationInWindow, from: nil)
        // Item menus are owned by the right-mouse monitor (`itemContextMenuItems`).
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
            mi.state = item.isOn ? .on : .off
            if item.isBold {
                let size = NSFont.menuFont(ofSize: 0).pointSize
                mi.attributedTitle = NSAttributedString(
                    string: item.title,
                    attributes: [.font: NSFont.boldSystemFont(ofSize: size)]
                )
            }
            if let image = item.image {
                mi.image = image
                Self.forceMenuImageVisible(mi)
            }
            menu.addItem(mi)
        }
        return menu
    }

    /// macOS 26+ may hide menu images unless visibility is forced (SwiftUI Label never reaches here).
    private static func forceMenuImageVisible(_ item: NSMenuItem) {
        let key = "preferredImageVisibility"
        guard item.responds(to: NSSelectorFromString("setPreferredImageVisibility:")) else { return }
        // `NSImageVisibility.visible` / UIKit equivalent raw value is 1.
        item.setValue(1, forKey: key)
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
        clearAcceptCache()
        return canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAccept(sender) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        clearAcceptCache()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        clearAcceptCache()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAccept(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { clearAcceptCache() }
        guard let onURLsDropped else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let contents = PasteboardIngest.read(from: sender.draggingPasteboard)
        guard !contents.isEmpty else { return false }
        onURLsDropped(contents, point)
        return true
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        guard onURLsDropped != nil else { return false }
        let changeCount = sender.draggingPasteboard.changeCount
        if acceptCacheChangeCount == changeCount {
            return acceptCacheResult
        }
        acceptCacheChangeCount = changeCount
        acceptCacheResult = !PasteboardIngest.read(from: sender.draggingPasteboard).isEmpty
        return acceptCacheResult
    }

    private func clearAcceptCache() {
        acceptCacheChangeCount = nil
        acceptCacheResult = false
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
