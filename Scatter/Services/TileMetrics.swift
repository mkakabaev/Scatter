import CoreGraphics

enum TileMetrics {
    /// Settings icon-size slider bounds (points). Favicon storage uses at least `max(maxIconSize×2, 512)` (see `WebFavicon`).
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

    /// Vertical padding above the icon and below the title frame.
    static let verticalPadding: CGFloat = 4
    /// Gap between the icon and the title.
    static let iconTitleSpacing: CGFloat = 4
    /// Slack under the title frame inside the tile (outside the text’s measured height).
    private static let titleBottomSlack: CGFloat = 8

    /// `verticalPadding`×2 + `iconTitleSpacing` + `titleBottomSlack`.
    static var verticalChrome: CGFloat {
        verticalPadding * 2 + iconTitleSpacing + titleBottomSlack
    }

    /// Icon + 2-line title + `verticalChrome`.
    static func itemHeight(iconSize: Double, labelSize: Double) -> CGFloat {
        CGFloat(iconSize) + titleHeight(labelSize: labelSize) + verticalChrome
    }
}
