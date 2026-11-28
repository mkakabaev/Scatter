import AppKit
import SwiftUI

extension CanvasView {
    /// Right / bottom edge hints when tiles are clipped by the window. Click expands to fit all.
    @ViewBuilder
    func overflowChevrons(canvasSize: CGSize) -> some View {
        let overflow = overflowEdges(canvasSize: canvasSize)
        let bottomPad: CGFloat = store.isSelectingItems && !store.selectedItemIDs.isEmpty ? 64 : 6
        // `.position` keeps hit targets button-sized (no full-canvas frame intercept).
        ZStack {
            if overflow.right {
                overflowChevronButton(systemName: "chevron.right")
                    .position(x: canvasSize.width - 17, y: canvasSize.height / 2)
            }
            if overflow.bottom {
                overflowChevronButton(systemName: "chevron.down")
                    .position(x: canvasSize.width / 2, y: canvasSize.height - bottomPad - 14)
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
    }

    private func overflowChevronButton(systemName: String) -> some View {
        Button {
            expandWindowToFitContent()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 22, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black.opacity(0.45))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Resize window to show all items")
    }

    private func overflowEdges(canvasSize: CGSize) -> (right: Bool, bottom: Bool) {
        let bounds = SnapToGrid.contentBounds(items: store.visibleItems, settings: store.state.settings)
        guard bounds != .null else { return (false, false) }
        // Top inset shifts the framed canvas down; bottom clips that much sooner.
        let right = bounds.maxX > canvasSize.width + 0.5
        let bottom = bounds.maxY + Self.canvasTopInset > canvasSize.height + 0.5
        guard right || bottom else { return (false, false) }
        // Only show a chevron when the window can still grow on that axis.
        let room = growRoom(for: canvasSize)
        return (right && room.width > 0.5, bottom && room.height > 0.5)
    }

    /// How much the canvas can still grow before hitting the screen’s visible frame.
    private func growRoom(for canvasSize: CGSize) -> CGSize {
        guard let window = launcherWindow(),
              let screen = window.screen ?? NSScreen.main else {
            return CGSize(width: 10_000, height: 10_000)
        }
        let visible = screen.visibleFrame
        let contentW = window.contentView?.bounds.width ?? window.frame.width
        let contentH = window.contentView?.bounds.height ?? window.frame.height
        let chromeW = window.frame.width - contentW
        let chromeH = window.frame.height - contentH
        // Keep the window’s top-left fixed; remaining room is to the right and down.
        let maxContentW = max(0, visible.maxX - window.frame.minX - chromeW)
        let maxContentH = max(0, window.frame.maxY - visible.minY - chromeH)
        let sidebar = SidebarLayout.clamped(
            store.state.settings.sidebarWidth,
            containerWidth: Double(contentW)
        )
        let maxCanvasW = max(0, maxContentW - sidebar - SidebarLayout.splitterThickness)
        return CGSize(
            width: max(0, maxCanvasW - canvasSize.width),
            height: max(0, maxContentH - contentH)
        )
    }

    /// Expand the main window so every visible tile fits (clamped to the display).
    private func expandWindowToFitContent() {
        guard let window = launcherWindow() else { return }
        let bounds = SnapToGrid.contentBounds(items: store.visibleItems, settings: store.state.settings)
        guard bounds != .null else { return }

        let contentW = window.contentView?.bounds.width ?? window.frame.width
        let contentH = window.contentView?.bounds.height ?? window.frame.height
        let sidebar = SidebarLayout.clamped(
            store.state.settings.sidebarWidth,
            containerWidth: Double(contentW)
        )
        let neededCanvasW = bounds.maxX + Self.fitContentMargin
        let neededCanvasH = bounds.maxY + Self.fitContentMargin + Self.canvasTopInset
        var targetContent = CGSize(
            width: max(contentW, sidebar + SidebarLayout.splitterThickness + neededCanvasW),
            height: max(contentH, neededCanvasH)
        )

        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            let chromeW = window.frame.width - contentW
            let chromeH = window.frame.height - contentH
            let maxContentW = max(640, visible.maxX - window.frame.minX - chromeW)
            let maxContentH = max(400, window.frame.maxY - visible.minY - chromeH)
            targetContent.width = min(targetContent.width, maxContentW)
            targetContent.height = min(targetContent.height, maxContentH)
        }

        let deltaW = targetContent.width - contentW
        let deltaH = targetContent.height - contentH
        guard deltaW > 0.5 || deltaH > 0.5 else { return }

        var frame = window.frame
        frame.size.width += deltaW
        frame.size.height += deltaH
        frame.origin.y -= deltaH // keep top edge fixed (AppKit y grows upward)
        window.setFrame(frame, display: true, animate: true)
    }
}
