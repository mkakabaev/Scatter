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

    var onClick: () -> Void
    /// Right-click menu for empty canvas / sidebar padding (AppKit — reliable over NSView).
    var contextMenuItems: [MenuItem] = []
    /// Dropped file/http URLs and the drop point in flipped view coordinates.
    var onURLsDropped: (([URL], CGPoint) -> Void)? = nil

    func makeNSView(context: Context) -> WindowBackgroundDragNSView {
        let view = WindowBackgroundDragNSView()
        view.onClick = onClick
        view.contextMenuItems = contextMenuItems
        view.onURLsDropped = onURLsDropped
        return view
    }

    func updateNSView(_ nsView: WindowBackgroundDragNSView, context: Context) {
        nsView.onClick = onClick
        nsView.contextMenuItems = contextMenuItems
        nsView.onURLsDropped = onURLsDropped
    }
}

final class WindowBackgroundDragNSView: NSView {
    var onClick: (() -> Void)?
    var contextMenuItems: [WindowBackgroundDragView.MenuItem] = []
    var onURLsDropped: (([URL], CGPoint) -> Void)?

    private var lastMenuPoint: CGPoint = .zero
    /// Retains leaf-item targets for the open context menu.
    private var menuHandlers: [ContextMenuHandler] = []

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

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard !contextMenuItems.isEmpty else { return nil }
        lastMenuPoint = convert(event.locationInWindow, from: nil)
        menuHandlers.removeAll(keepingCapacity: true)
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
