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
        /// Canvas/local point where the context menu was opened (flipped view coords).
        var action: (CGPoint) -> Void
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
        let menu = NSMenu()
        for (index, item) in contextMenuItems.enumerated() {
            let mi = NSMenuItem(
                title: item.title,
                action: #selector(invokeContextMenuItem(_:)),
                keyEquivalent: ""
            )
            mi.target = self
            mi.tag = index
            menu.addItem(mi)
        }
        return menu
    }

    @objc private func invokeContextMenuItem(_ sender: NSMenuItem) {
        let index = sender.tag
        guard contextMenuItems.indices.contains(index) else { return }
        let point = lastMenuPoint
        contextMenuItems[index].action(point)
    }

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
        let urls = Self.urls(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onURLsDropped(urls, point)
        return true
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        guard onURLsDropped != nil else { return false }
        return !Self.urls(from: sender.draggingPasteboard).isEmpty
            || ItemOpener.draggedWebLink() != nil
    }

    /// Prefer on-disk file URLs; otherwise http(s) from the drag pasteboard; otherwise any URL.
    private static func urls(from pasteboard: NSPasteboard) -> [URL] {
        if let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !files.isEmpty {
            return files.filter { FileManager.default.fileExists(atPath: $0.path) }
        }

        if let link = ItemOpener.draggedWebLink() {
            return [link.url]
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            return urls
        }

        // Last resort: raw public.file-url / public.url strings on the pasteboard.
        if let paths = pasteboard.propertyList(forType: .fileURL) as? [String] {
            let urls = paths.compactMap { URL(string: $0) ?? URL(fileURLWithPath: $0) }
            if !urls.isEmpty { return urls }
        }
        return []
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
