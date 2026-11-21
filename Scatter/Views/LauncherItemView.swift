import SwiftUI

struct LauncherItemView: View {
    let item: LauncherItem
    let iconSize: CGFloat
    let labelSize: CGFloat
    let isSelected: Bool

    private var titleHeight: CGFloat { TileMetrics.titleHeight(labelSize: labelSize) }
    private var titleWidth: CGFloat { iconSize + TileMetrics.titleSideInset * 2 }

    /// Matches the vertical padding and the icon-to-title gap in `body`.
    private let tilePaddingV: CGFloat = 4
    private let iconTitleSpacing: CGFloat = 4

    /// SwiftUI’s rendered title height. Seeded with an AppKit estimate so the first frame is already shrunk.
    @State private var measuredTitleHeight: CGFloat?

    var body: some View {
        VStack(spacing: iconTitleSpacing) {
            LauncherItemIconView(item: item, size: iconSize)

            Text(item.displayName)
                .font(.system(size: labelSize))
                .foregroundStyle(titleOnLight ? Color.black.opacity(0.88) : Color.white.opacity(0.92))
                .shadow(
                    color: .black.opacity(titleOnLight ? 0.2 : 0.45),
                    radius: titleOnLight ? 1 : 2,
                    y: titleOnLight ? 0.5 : 1
                )
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: TitleBlockHeightKey.self, value: proxy.size.height)
                    }
                )
                .frame(width: titleWidth, height: titleHeight, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, TileMetrics.horizontalPadding)
        .padding(.vertical, tilePaddingV)
        .background(alignment: .top) {
            RoundedRectangle(cornerRadius: 10)
                .fill(tileFill)
                .frame(height: huggedFillHeight, alignment: .top)
        }
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.8) : Color.clear, lineWidth: 2)
                .frame(height: huggedFillHeight, alignment: .top)
        }
        .help(item.displayName)
        .onPreferenceChange(TitleBlockHeightKey.self) { measuredTitleHeight = $0 }
    }

    /// `nil` fills the tile (two lines). One line uses the measured text in place of the two-line slot, plus the same chrome (including the 8pt under the title).
    private var huggedFillHeight: CGFloat? {
        let textHeight = measuredTitleHeight ?? estimatedTitleHeight
        guard textHeight > 0 else { return nil }
        if textHeight > singleLineHeight * 1.5 { return nil }
        return iconSize + textHeight + TileMetrics.verticalChrome
    }

    private var tileColor: Color? {
        guard let hex = item.backgroundColorHex else { return nil }
        return ItemBackgroundPicker.color(hex: hex)
    }

    /// Light tile fill uses a black title and a softer shadow. Missing or dark fill stays white with the stronger shadow.
    private var titleOnLight: Bool {
        guard let hex = item.backgroundColorHex, let color = NSColor(hex: hex) else { return false }
        return color.isLightBackground
    }

    private var tileFill: Color {
        if let tileColor {
            return tileColor
        }
        return isSelected ? Color.white.opacity(0.14) : Color.clear
    }

    private var singleLineHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: labelSize)
        return max(1, font.ascender - font.descender + font.leading)
    }

    private var estimatedTitleHeight: CGFloat {
        let font = NSFont.systemFont(ofSize: labelSize)
        let text = item.displayName.isEmpty ? " " : item.displayName
        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, titleWidth), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 2
        container.lineBreakMode = .byTruncatingTail
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}

private struct TitleBlockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
