import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum IconProvider {
    /// Main tile icon. `.code-workspace` files always use Cursor’s icon.
    @MainActor
    static func icon(for item: LauncherItem, size: CGFloat) -> NSImage {
        let image: NSImage
        if isCodeWorkspace(item), let cursor = CursorLocator.applicationURL {
            image = NSWorkspace.shared.icon(forFile: cursor.path)
        } else if item.kind == .url, let data = item.iconPNGData, let favicon = NSImage(data: data) {
            favicon.isTemplate = false
            return insetLikeMacOSIcon(favicon, pointSize: size)
        } else if item.kind == .url {
            image = NSWorkspace.shared.icon(for: UTType.html)
        } else if let url = item.resolvedURL() {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        return scaled(image, to: size)
    }

    /// Small Open With badge. `nil` when none, or when the main icon already is Cursor for workspaces.
    static func openWithBadgeIcon(for item: LauncherItem, size: CGFloat) -> NSImage? {
        if isCodeWorkspace(item) { return nil }
        guard hasOpenWith(item),
              let appURL = ItemOpener.resolveOpenWithApp(for: item) else {
            return nil
        }
        return scaled(NSWorkspace.shared.icon(forFile: appURL.path), to: size)
    }

    static func hasOpenWith(_ item: LauncherItem) -> Bool {
        item.openWithBundleIdentifier != nil || item.openWithBookmarkData != nil
    }

    static func isCodeWorkspace(_ item: LauncherItem) -> Bool {
        if let url = item.resolvedURL() {
            return url.pathExtension.lowercased() == "code-workspace"
        }
        if let urlString = item.urlString, let url = URL(string: urlString) {
            return url.pathExtension.lowercased() == "code-workspace"
        }
        return item.displayName.lowercased().hasSuffix(".code-workspace")
    }

    /// Apple’s macOS icon grid: an 824 px body centered on a 1024 px canvas (100 px transparent margin).
    fileprivate static let macOSIconContentScale: CGFloat = 824.0 / 1024.0

    /// Corner radius as a fraction of the favicon body side — matches macOS app-icon continuous rounding (~22.37%).
    fileprivate static let webIconCornerRadiusFraction: CGFloat = 0.2237

    /// Draw `image` at the icon-grid body size so a full-bleed favicon matches neighboring app icons.
    /// Web icons get a continuous (squircle) clip via SwiftUI `RoundedRectangle(..., style: .continuous)`.
    @MainActor
    private static func insetLikeMacOSIcon(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let renderer = ImageRenderer(content: WebIconCanvas(image: image, pointSize: pointSize))
        renderer.scale = scale
        guard let rendered = renderer.nsImage else {
            return scaled(image, to: pointSize)
        }
        rendered.isTemplate = false
        return rendered
    }

    private static func scaled(_ image: NSImage, to size: CGFloat) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}

/// Favicon inset on the macOS icon grid, clipped with a continuous squircle.
private struct WebIconCanvas: View {
    let image: NSImage
    let pointSize: CGFloat

    var body: some View {
        let content = pointSize * IconProvider.macOSIconContentScale
        let source = image.size
        let sourceSide = max(source.width, source.height, 1)
        let fitted = content / sourceSide
        let drawSize = CGSize(width: source.width * fitted, height: source.height * fitted)
        let cornerRadius = min(drawSize.width, drawSize.height) * IconProvider.webIconCornerRadiusFraction

        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: drawSize.width, height: drawSize.height)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .frame(width: pointSize, height: pointSize)
    }
}
