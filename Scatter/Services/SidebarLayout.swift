import Foundation

/// Collection sidebar width limits. The stored width is the user's choice; layout clamps it
/// so the icon canvas keeps a usable minimum when the window is narrow.
enum SidebarLayout {
    static let defaultWidth: Double = 206
    static let minimumWidth: Double = 140
    static let maximumWidth: Double = 420
    static let minimumCanvasWidth: Double = 280
    static let splitterThickness: Double = 8

    static func clamped(_ width: Double, containerWidth: Double) -> Double {
        let room = containerWidth - minimumCanvasWidth - splitterThickness
        let upper = min(maximumWidth, max(minimumWidth, room))
        return min(max(width, minimumWidth), upper)
    }
}
