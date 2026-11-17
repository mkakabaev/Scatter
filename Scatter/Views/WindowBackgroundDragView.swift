import AppKit
import SwiftUI

/// Empty-area hit target: click runs `onClick`; drag past a small threshold moves the window.
/// Uses AppKit so `performDrag(with:)` receives the original mouse-down event.
struct WindowBackgroundDragView: NSViewRepresentable {
    var onClick: () -> Void

    func makeNSView(context: Context) -> WindowBackgroundDragNSView {
        let view = WindowBackgroundDragNSView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: WindowBackgroundDragNSView, context: Context) {
        nsView.onClick = onClick
    }
}

final class WindowBackgroundDragNSView: NSView {
    var onClick: (() -> Void)?

    /// Match item-drag threshold in `FreeformCanvasView`.
    private let dragThreshold: CGFloat = 4

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

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
