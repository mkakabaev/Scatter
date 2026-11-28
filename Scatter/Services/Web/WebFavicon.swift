import AppKit
import Foundation
import ImageIO

/// Favicon / touch-icon candidate discovery and PNG rendering for web-link enrichment.
enum WebFavicon {
    /// Largest side stored in the favicon sidecar (`ItemIconStore`). Fetched once at drop and must stay sharp
    /// if the user later raises Settings icon size. Floor at 512 so common apple-touch / touch-icon
    /// sources (180–512) are kept at full strength; never upscale smaller bitmaps.
    static let maxIconPixels = max(Int(TileMetrics.maxIconSize) * 2, 512)
    static let maxDownloads = 8

    struct RenderedIcon {
        var sourceSide: Int
        var sourceArea: Int
        var png: Data
    }

    private struct IconRef {
        var url: URL
        var declaredSize: Int
    }

    /// Safari-oriented order: square OG touch art, apple-touch, manifest, generic `<link rel=icon>`, well-known paths.
    static func iconCandidates(html: String?, pageURL: URL, finalURL: URL) async -> [URL] {
        var candidates: [URL] = []
        if let html {
            if let og = squareOGImageURL(in: html, base: finalURL) {
                candidates.append(og)
            }
            candidates.append(contentsOf: appleTouchIconURLs(in: html, base: finalURL))
            if let manifest = manifestURL(in: html, base: finalURL) {
                if Task.isCancelled { return candidates }
                candidates.append(contentsOf: await manifestIconURLs(from: manifest))
            }
            candidates.append(contentsOf: genericIconURLs(in: html, base: finalURL))
        }
        appendWellKnownIconFallbacks(to: &candidates, from: pageURL)
        if !sameHost(pageURL, finalURL) {
            appendWellKnownIconFallbacks(to: &candidates, from: finalURL)
        }
        return candidates
    }

    static func looksLikeImage(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.starts(with: [0x47, 0x49, 0x46]) { return true }
        if data.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }
        return false
    }

    /// Largest frame in the file (an `.ico` often holds 16, 32, and 256). Downscale only above `maxIconPixels`.
    /// Drawn with ImageIO. `NSImageRep.draw` places an `.ico` frame in the top-right of the bitmap.
    static func renderedPNG(from data: Data) async -> RenderedIcon? {
        guard let sourceImage = largestCGImage(from: data) else { return nil }
        let pixelsWide = sourceImage.width
        let pixelsHigh = sourceImage.height
        let sourcePixels = max(pixelsWide, pixelsHigh)
        guard sourcePixels >= 1 else { return nil }
        let scale = min(1, Double(maxIconPixels) / Double(sourcePixels))
        let width = max(1, Int((Double(pixelsWide) * scale).rounded(.down)))
        let height = max(1, Int((Double(pixelsHigh) * scale).rounded(.down)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: rendered)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return RenderedIcon(
            sourceSide: sourcePixels,
            sourceArea: pixelsWide * pixelsHigh,
            png: png
        )
    }

    // MARK: - Candidates

    /// Square `og:image` only (Avito ships a 512 touch icon here). Skips typical 1.91:1 share cards.
    private static func squareOGImageURL(in html: String, base: URL) -> URL? {
        guard let raw = WebHTML.metaContent(in: html, property: "og:image") else { return nil }
        let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty, !decoded.lowercased().hasPrefix("data:") else { return nil }
        if decoded.lowercased().hasSuffix(".svg") { return nil }
        guard let resolved = URL(string: decoded, relativeTo: base)?.absoluteURL, resolved.isHTTP else {
            return nil
        }

        let width = WebHTML.metaContent(in: html, property: "og:image:width").flatMap(Int.init)
        let height = WebHTML.metaContent(in: html, property: "og:image:height").flatMap(Int.init)
        if let width, let height {
            guard width == height, width >= 32 else { return nil }
        } else if !pathLooksLikeIcon(resolved) {
            return nil
        }
        return resolved
    }

    /// `rel=apple-touch-icon` / `apple-touch-icon-precomposed` — Safari bookmark quality on macOS.
    private static func appleTouchIconURLs(in html: String, base: URL) -> [URL] {
        linkIconURLs(in: html, base: base) { isAppleTouchRel($0) }
    }

    /// Generic `rel=icon` / `shortcut icon` (excludes apple-touch and mask icons).
    private static func genericIconURLs(in html: String, base: URL) -> [URL] {
        linkIconURLs(in: html, base: base) { isGenericIconRel($0) }
    }

    private static func linkIconURLs(in html: String, base: URL, relMatch: (String) -> Bool) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<link\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let ns = html as NSString
        var refs: [IconRef] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let attrs = WebHTML.attributes(in: tag)
            guard let rel = attrs["rel"]?.lowercased(), relMatch(rel), let href = attrs["href"] else { continue }
            let decoded = href
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty, !decoded.lowercased().hasPrefix("data:") else { continue }
            if decoded.lowercased().hasSuffix(".svg") || attrs["type"]?.lowercased().contains("svg") == true {
                continue
            }
            guard let resolved = URL(string: decoded, relativeTo: base)?.absoluteURL, resolved.isHTTP else { continue }
            refs.append(IconRef(url: resolved, declaredSize: largestSize(attrs["sizes"] ?? "")))
        }
        return orderedIconURLs(refs)
    }

    /// `rel=manifest` href from the page, if any.
    private static func manifestURL(in html: String, base: URL) -> URL? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<link\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let attrs = WebHTML.attributes(in: tag)
            guard let rel = attrs["rel"]?.lowercased() else { continue }
            let tokens = rel.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.contains("manifest"), let href = attrs["href"] else { continue }
            let decoded = href
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty, !decoded.lowercased().hasPrefix("data:") else { continue }
            guard let resolved = URL(string: decoded, relativeTo: base)?.absoluteURL, resolved.isHTTP else {
                continue
            }
            return resolved
        }
        return nil
    }

    /// Icons from a web app manifest, largest declared size first. Skips SVG and monochrome entries.
    private static func manifestIconURLs(from manifestURL: URL) async -> [URL] {
        guard let data = await WebLinkHTTP.downloadManifest(manifestURL) else { return [] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let icons = root["icons"] as? [[String: Any]] else { return [] }

        var refs: [IconRef] = []
        for icon in icons {
            guard let src = icon["src"] as? String else { continue }
            let decoded = src.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty, !decoded.lowercased().hasPrefix("data:") else { continue }
            let type = (icon["type"] as? String)?.lowercased() ?? ""
            if decoded.lowercased().hasSuffix(".svg") || type.contains("svg") { continue }
            if let purpose = icon["purpose"] as? String {
                let tokens = purpose.lowercased().split(whereSeparator: { $0.isWhitespace })
                if tokens.contains("monochrome") { continue }
            }
            // Relative paths resolve against the manifest URL per the Web App Manifest spec.
            guard let resolved = URL(string: decoded, relativeTo: manifestURL)?.absoluteURL, resolved.isHTTP else {
                continue
            }
            let sizes = icon["sizes"] as? String ?? ""
            refs.append(IconRef(url: resolved, declaredSize: largestSize(sizes)))
        }
        return orderedIconURLs(refs)
    }

    /// Origin fallbacks when HTML is thin or blocked: apple-touch first (Safari-like), then favicon.ico.
    private static func appendWellKnownIconFallbacks(to candidates: inout [URL], from pageURL: URL) {
        if let touch = wellKnownURL(from: pageURL, path: "/apple-touch-icon.png") {
            candidates.append(touch)
        }
        if let touchPre = wellKnownURL(from: pageURL, path: "/apple-touch-icon-precomposed.png") {
            candidates.append(touchPre)
        }
        // Auth/SSO redirects change finalURL; the dropped origin often still serves a usable favicon.
        if let favicon = wellKnownURL(from: pageURL, path: "/favicon.ico") {
            candidates.append(favicon)
        }
    }

    // MARK: - Helpers

    /// Largest declared size first, then icons with no `sizes` (often the high-res default), then smaller ones.
    private static func orderedIconURLs(_ refs: [IconRef]) -> [URL] {
        let sized = refs.filter { $0.declaredSize > 0 }.sorted { $0.declaredSize > $1.declaredSize }
        let unsized = refs.filter { $0.declaredSize == 0 }
        var ordered: [URL] = []
        if let largest = sized.first {
            ordered.append(largest.url)
        }
        ordered.append(contentsOf: unsized.map(\.url))
        ordered.append(contentsOf: sized.dropFirst().map(\.url))
        return ordered
    }

    private static func relTokens(_ rel: String) -> [String] {
        rel.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func isAppleTouchRel(_ rel: String) -> Bool {
        relTokens(rel).contains { $0.contains("apple-touch-icon") }
    }

    private static func isGenericIconRel(_ rel: String) -> Bool {
        let tokens = relTokens(rel)
        if tokens.contains(where: { $0.contains("mask") || $0.contains("apple-touch-icon") }) { return false }
        return tokens.contains { $0.contains("icon") }
    }

    private static func pathLooksLikeIcon(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        return path.contains("icon") || path.contains("favicon") || path.contains("apple-touch")
    }

    private static func wellKnownURL(from pageURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func largestSize(_ sizes: String) -> Int {
        var best = 0
        for part in sizes.split(whereSeparator: { $0.isWhitespace }) {
            guard let side = part.split(separator: "x").first.flatMap({ Int($0) }) else { continue }
            best = max(best, side)
        }
        return best
    }

    private static func largestCGImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        var best: CGImage?
        var bestArea = 0
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let area = image.width * image.height
            if area > bestArea {
                best = image
                bestArea = area
            }
        }
        return best
    }

    private static func sameHost(_ a: URL, _ b: URL) -> Bool {
        guard let left = a.host?.lowercased(), let right = b.host?.lowercased() else { return false }
        return left == right
    }
}
