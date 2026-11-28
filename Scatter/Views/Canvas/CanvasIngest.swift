import AppKit
import SwiftUI

extension CanvasView {
    var openChoiceTitle: String {
        guard let pending = pendingDrop, let first = pending.openChoiceItems.first else {
            return "Open With"
        }
        if pending.openChoiceItems.count == 1 {
            return "Open “\(first.displayName)”"
        }
        return "Open \(pending.openChoiceItems.count) Items"
    }

    func commitPendingDrop(openWithCursor: Bool) {
        guard let pending = pendingDrop else { return }
        if openWithCursor, CursorLocator.applicationURL == nil {
            pendingDrop = nil
            store.reportIngestFailure("Cursor could not be found. Install Cursor or choose Default.")
            return
        }
        for item in pending.otherItems {
            if item.kind == .url {
                store.addWebLink(item)
            } else {
                store.addItemFromFinder(item, openWithCursor: false)
            }
        }
        for item in pending.openChoiceItems {
            store.addItemFromFinder(item, openWithCursor: openWithCursor)
        }
        pendingDrop = nil
    }

    /// `canvasPoint` is the right-click location in the empty-canvas view (tile centers on it, same as drop).
    func pickAndAdd(at canvasPoint: CGPoint) {
        let dropPoint = CGPoint(
            x: max(0, canvasPoint.x - itemWidth / 2),
            y: max(0, canvasPoint.y - itemHeight / 2)
        )
        guard let urls = AddItemsPanel.run() else { return }
        let items = urls.compactMap { LauncherItemFactory.makeItem(from: $0, at: dropPoint) }
        commitIngest(items)
    }

    /// AppKit canvas drop: `location` is in the empty-canvas view (flipped).
    func handleCanvasDrop(_ contents: PasteboardContents, at location: CGPoint) {
        let dropPoint = CGPoint(
            x: max(0, location.x - itemWidth / 2),
            y: max(0, location.y - itemHeight / 2)
        )
        ingestPasteboard(contents, proposing: dropPoint)
    }

    /// ⌘V: same ingest as drop. Prefer the cell under the pointer when it is over the canvas;
    /// otherwise the next free grid cell(s).
    func pasteFromClipboard() {
        let contents = PasteboardIngest.read(from: .general)
        guard !contents.isEmpty else {
            NSSound.beep()
            return
        }

        if let location = canvasPointUnderMouse() {
            let dropPoint = CGPoint(
                x: max(0, location.x - itemWidth / 2),
                y: max(0, location.y - itemHeight / 2)
            )
            ingestPasteboard(contents, proposing: dropPoint)
            return
        }

        var proposing = SnapToGrid.nextFreePlacement(
            items: store.visibleItems,
            settings: store.state.settings,
            canvasSize: canvasSize
        )
        var occupied = store.visibleItems
        var prepared: [LauncherItem] = []
        for entry in contents.items {
            guard var item = LauncherItemFactory.makeItem(
                from: entry.url,
                at: proposing.point,
                title: entry.title
            ) else { continue }
            item.gridColumn = proposing.cell.column
            item.gridRow = proposing.cell.row
            prepared.append(item)
            occupied.append(item)
            proposing = SnapToGrid.nextFreePlacement(
                items: occupied,
                settings: store.state.settings,
                canvasSize: canvasSize
            )
        }
        commitIngest(prepared)
    }

    /// Pointer location in the canvas drop view when it sits over that view; else nil (sidebar / outside).
    private func canvasPointUnderMouse() -> CGPoint? {
        guard let window = NSApp.windows.first(where: { $0 is LauncherWindow && $0.isVisible })
                ?? NSApp.keyWindow,
              let canvas = WindowBackgroundDragNSView.canvasDropTarget(in: window.contentView) else {
            return nil
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = canvas.convert(windowPoint, from: nil)
        guard canvas.bounds.contains(local) else { return nil }
        return local
    }

    private func ingestPasteboard(_ contents: PasteboardContents, proposing dropPoint: CGPoint) {
        let items = contents.items.compactMap {
            LauncherItemFactory.makeItem(from: $0.url, at: dropPoint, title: $0.title)
        }
        commitIngest(items)
    }

    /// Shared kind branch for drop / paste / Add…. Call sites only choose positions.
    /// When any file/folder needs the Open With dialog, the whole batch waits for confirm/cancel.
    private func commitIngest(_ items: [LauncherItem]) {
        guard !items.isEmpty else { return }
        // Do not replace a batch waiting on Default / Open With Cursor / Cancel.
        if pendingDrop != nil {
            NSSound.beep()
            return
        }
        var openChoiceItems: [LauncherItem] = []
        var otherItems: [LauncherItem] = []
        for item in items {
            if item.kind.offersOpenWithOnDrop {
                openChoiceItems.append(item)
            } else {
                otherItems.append(item)
            }
        }
        if openChoiceItems.isEmpty {
            for item in otherItems {
                if item.kind == .url {
                    store.addWebLink(item)
                } else {
                    store.addItemFromFinder(item, openWithCursor: false)
                }
            }
            return
        }
        pendingDrop = PendingDrop(openChoiceItems: openChoiceItems, otherItems: otherItems)
    }
}
