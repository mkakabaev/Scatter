import SwiftUI

/// Main item icon with optional Open With app badge (bottom-trailing).
struct LauncherItemIconView: View {
    let item: LauncherItem
    let size: CGFloat
    /// Drop shadow under the main icon (tiles on). Search rows keep it off.
    var showsShadow: Bool = true

    private var badgeSize: CGFloat { max(16, size * 0.38) }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: IconProvider.icon(for: item, size: size))
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(showsShadow ? 0.35 : 0), radius: showsShadow ? 4 : 0, y: showsShadow ? 2 : 0)

            if let badge = IconProvider.openWithBadgeIcon(for: item, size: badgeSize) {
                Image(nsImage: badge)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: badgeSize, height: badgeSize)
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: size, height: size)
    }
}
