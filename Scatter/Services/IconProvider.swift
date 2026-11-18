import AppKit
import UniformTypeIdentifiers

enum IconProvider {
    /// Main tile icon. `.code-workspace` files always use Cursor’s icon.
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
    private static let macOSIconContentScale: CGFloat = 824.0 / 1024.0

    /// Draw `image` at the icon-grid body size so a full-bleed favicon matches neighboring app icons.
    /// The bitmap context’s user space is `bitmap.size` (the pixel size, at 72 dpi). Draw in that space, then
    /// assign the tile’s point size. Drawing in raw pixels after shrinking `size` pins the graphic to the top-right.
    private static func insetLikeMacOSIcon(_ image: NSImage, pointSize: CGFloat) -> NSImage {
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let pixels = max(1, Int((pointSize * scale).rounded()))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return scaled(image, to: pointSize)
        }

        let canvasSide = max(bitmap.size.width, bitmap.size.height, 1)
        let content = canvasSide * macOSIconContentScale
        let source = image.size
        let sourceSide = max(source.width, source.height, 1)
        let fitted = content / sourceSide
        let drawSize = NSSize(width: source.width * fitted, height: source.height * fitted)
        let origin = NSPoint(
            x: (bitmap.size.width - drawSize.width) / 2,
            y: (bitmap.size.height - drawSize.height) / 2
        )

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: NSRect(origin: .zero, size: source),
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        bitmap.size = NSSize(width: pointSize, height: pointSize)
        let canvas = NSImage(size: bitmap.size)
        canvas.addRepresentation(bitmap)
        canvas.isTemplate = false
        return canvas
    }

    private static func scaled(_ image: NSImage, to size: CGFloat) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = NSSize(width: size, height: size)
        return copy
    }
}
