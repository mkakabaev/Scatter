import CoreGraphics

enum TileMetrics {
    /// Settings icon-size slider bounds (points). Favicon storage uses `maxIconSize` at 2× (see `WebLinkFetcher`).
    static let minIconSize: Double = 36
    static let maxIconSize: Double = 128

    /// Vertical space reserved for the item title (exactly two text lines).
    static func titleHeight(labelSize: Double) -> CGFloat {
        ceil(CGFloat(labelSize) * 2.6)
    }

    /// Title column is this much wider than the icon (8pt each side).
    static let titleSideInset: CGFloat = 8
    /// Gap between the title column and the tile edge. Included in `itemWidth`, so the painted background matches the grid cell.
    static let horizontalPadding: CGFloat = 6

    /// Icon + title side room + horizontal padding. This is the painted tile width.
    static func itemWidth(iconSize: Double) -> CGFloat {
        CGFloat(iconSize) + titleSideInset * 2 + horizontalPadding * 2
    }

    /// Vertical padding (4+4), icon-to-title gap (4), and the slack under the title frame (8).
    static let verticalChrome: CGFloat = 20

    /// Icon + 2-line title + `verticalChrome`.
    static func itemHeight(iconSize: Double, labelSize: Double) -> CGFloat {
        CGFloat(iconSize) + titleHeight(labelSize: labelSize) + verticalChrome
    }
}
