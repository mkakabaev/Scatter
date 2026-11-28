import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum IconProvider {
    /// Favicon ImageRenderer results keyed by PNG bytes + point size + backing scale.
    @MainActor
    private static var faviconCache: [FaviconCacheKey: NSImage] = [:]

    /// Main tile icon. `.code-workspace` files always use Cursor’s icon.
    @MainActor
    static func icon(for item: LauncherItem, size: CGFloat) -> NSImage {
        let image: NSImage
        if ItemURLResolver.isCodeWorkspace(item), let cursor = CursorLocator.applicationURL {
            image = NSWorkspace.shared.icon(forFile: cursor.path)
        } else if item.kind == .url, let data = item.iconPNGData, let favicon = NSImage(data: data) {
            favicon.isTemplate = false
            return insetLikeMacOSIcon(favicon, pngData: data, pointSize: size)
        } else if item.kind == .url {
            image = NSWorkspace.shared.icon(for: UTType.html)
        } else if let url = ItemURLResolver.resolve(item) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        return scaled(image, to: size)
    }

    /// System icon for an app (or any on-disk) URL. Default size matches AppKit menu rows.
    static func icon(forApplicationAt url: URL, size: CGFloat = 16) -> NSImage {
        scaled(NSWorkspace.shared.icon(forFile: url.path), to: size)
    }

    /// Small Open With badge. `nil` when none, apps (never Open With), or workspace tiles that already use Cursor’s icon.
    static func openWithBadgeIcon(for item: LauncherItem, size: CGFloat) -> NSImage? {
        guard item.supportsOpenWith else { return nil }
        if ItemURLResolver.isCodeWorkspace(item) { return nil }
        guard let resolved = OpenWithResolver.resolve(for: item) else {
            return nil
        }
        return icon(forApplicationAt: resolved.url, size: size)
    }

    /// Draw `image` at the icon-grid body size so a full-bleed favicon matches neighboring app icons.
    /// Web icons get a continuous (squircle) clip via SwiftUI `RoundedRectangle(..., style: .continuous)`.
    @MainActor
    private static func insetLikeMacOSIcon(_ image: NSImage, pngData: Data, pointSize: CGFloat) -> NSImage {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let key = FaviconCacheKey(pngData: pngData, pointSize: pointSize, scale: scale)
        if let cached = faviconCache[key] {
            return cached
        }
        let renderer = ImageRenderer(content: WebIconCanvas(image: image, pointSize: pointSize))
        renderer.scale = scale
        guard let rendered = renderer.nsImage else {
            return scaled(image, to: pointSize)
        }
        rendered.isTemplate = false
        faviconCache[key] = rendered
        return rendered
    }

    /// Never mutate `NSWorkspace` / shared icon instances — always draw into a fresh image.
    private static func scaled(_ image: NSImage, to size: CGFloat) -> NSImage {
        let target = NSSize(width: size, height: size)
        return NSImage(size: target, flipped: false) { bounds in
            image.draw(
                in: bounds,
                from: NSRect(origin: .zero, size: image.size),
                operation: .copy,
                fraction: 1
            )
            return true
        }
    }
}

@MainActor
private struct FaviconCacheKey: Hashable {
    let pngHash: Int
    let pngCount: Int
    let pointSize: CGFloat
    let scale: CGFloat

    init(pngData: Data, pointSize: CGFloat, scale: CGFloat) {
        var hasher = Hasher()
        hasher.combine(pngData)
        pngHash = hasher.finalize()
        pngCount = pngData.count
        self.pointSize = pointSize
        self.scale = scale
    }
}

/// Favicon inset on the macOS icon grid, clipped with a continuous squircle.
private struct WebIconCanvas: View {
    /// Apple’s macOS icon grid: an 824 px body centered on a 1024 px canvas (100 px transparent margin).
    private static let macOSIconContentScale: CGFloat = 824.0 / 1024.0

    /// Corner radius as a fraction of the favicon body side — matches macOS app-icon continuous rounding (~22.37%).
    private static let cornerRadiusFraction: CGFloat = 0.2237

    let image: NSImage
    let pointSize: CGFloat

    var body: some View {
        let content = pointSize * Self.macOSIconContentScale
        let source = image.size
        let sourceSide = max(source.width, source.height, 1)
        let fitted = content / sourceSide
        let drawSize = CGSize(width: source.width * fitted, height: source.height * fitted)
        let cornerRadius = min(drawSize.width, drawSize.height) * Self.cornerRadiusFraction

        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: drawSize.width, height: drawSize.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .frame(width: pointSize, height: pointSize)
    }
}
