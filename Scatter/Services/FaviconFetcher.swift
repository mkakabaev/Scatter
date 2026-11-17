import AppKit
import Foundation
import ImageIO

/// Loads a site icon for a dropped http(s) link and returns PNG bytes for the tile.
enum FaviconFetcher {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.urlCache = nil
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        return URLSession(configuration: config)
    }()

    private static let htmlByteLimit = 256 * 1024
    private static let imageByteLimit = 1_500_000
    /// Largest side stored. 128 pt tiles at 2x need 256 px; anything bigger is scaled down, never up.
    private static let maxIconPixels = 256
    private static let maxDownloads = 8

    static func fetchPNG(for pageURL: URL) async -> Data? {
        guard isHTTP(pageURL) else { return nil }

        var candidates: [URL] = []
        if let page = await fetchPrefix(from: pageURL, limit: htmlByteLimit) {
            if looksLikeImage(page.data), let rendered = await renderedPNG(from: page.data) {
                return rendered.png
            }
            if let html = String(data: page.data, encoding: .utf8) ?? String(data: page.data, encoding: .isoLatin1) {
                candidates = iconURLs(in: html, base: page.finalURL)
            }
            if let fallback = faviconURL(from: page.finalURL) {
                candidates.append(fallback)
            }
        } else if let fallback = faviconURL(from: pageURL) {
            candidates = [fallback]
        }

        var seen = Set<String>()
        var best: RenderedIcon?
        var downloads = 0
        for candidate in candidates {
            guard seen.insert(candidate.absoluteString).inserted else { continue }
            guard downloads < maxDownloads else { break }
            downloads += 1
            guard let data = await downloadImage(candidate) else { continue }
            guard let rendered = await renderedPNG(from: data) else { continue }
            if best == nil || rendered.sourceArea > best!.sourceArea {
                best = rendered
            }
        }
        return best?.png
    }

    private struct PagePrefix {
        var data: Data
        var finalURL: URL
    }

    private struct IconRef {
        var url: URL
        var declaredSize: Int
    }

    private struct RenderedIcon {
        var sourceArea: Int
        var png: Data
    }

    private static func fetchPrefix(from url: URL, limit: Int) async -> PagePrefix? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("text/html,application/xhtml+xml;q=0.9,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            var data = Data()
            data.reserveCapacity(min(limit, 64 * 1024))
            do {
                for try await byte in bytes {
                    data.append(byte)
                    if data.count >= limit {
                        bytes.task.cancel()
                        break
                    }
                }
            } catch {
                if data.isEmpty { return nil }
            }
            return PagePrefix(data: data, finalURL: response.url ?? url)
        } catch {
            return nil
        }
    }

    private static func downloadImage(_ url: URL) async -> Data? {
        guard isHTTP(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("image/png,image/jpeg,image/x-icon,image/*;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard !data.isEmpty, data.count <= imageByteLimit else { return nil }
            if http.mimeType?.lowercased().hasPrefix("text/") == true { return nil }
            return data
        } catch {
            return nil
        }
    }

    private static func iconURLs(in html: String, base: URL) -> [URL] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<link\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.caseInsensitive]
        ) else { return [] }

        let ns = html as NSString
        var refs: [IconRef] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let attrs = attributes(in: tag)
            guard let rel = attrs["rel"]?.lowercased(), isIconRel(rel), let href = attrs["href"] else { continue }
            let decoded = href
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty, !decoded.lowercased().hasPrefix("data:") else { continue }
            if decoded.lowercased().hasSuffix(".svg") || attrs["type"]?.lowercased().contains("svg") == true {
                continue
            }
            guard let resolved = URL(string: decoded, relativeTo: base)?.absoluteURL, isHTTP(resolved) else { continue }
            refs.append(IconRef(url: resolved, declaredSize: largestSize(attrs["sizes"] ?? "")))
        }
        return orderedIconURLs(refs)
    }

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

    private static func isIconRel(_ rel: String) -> Bool {
        let tokens = rel.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.contains(where: { $0.contains("mask") }) { return false }
        return tokens.contains { $0.contains("icon") }
    }

    private static func largestSize(_ sizes: String) -> Int {
        var best = 0
        for part in sizes.split(whereSeparator: { $0.isWhitespace }) {
            guard let side = part.split(separator: "x").first.flatMap({ Int($0) }) else { continue }
            best = max(best, side)
        }
        return best
    }

    private static func attributes(in tag: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(
            pattern: #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
            options: []
        ) else { return [:] }
        let ns = tag as NSString
        var result: [String: String] = [:]
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            let value: String
            if match.range(at: 2).location != NSNotFound {
                value = ns.substring(with: match.range(at: 2))
            } else if match.range(at: 3).location != NSNotFound {
                value = ns.substring(with: match.range(at: 3))
            } else if match.range(at: 4).location != NSNotFound {
                value = ns.substring(with: match.range(at: 4))
            } else {
                continue
            }
            result[key] = value
        }
        return result
    }

    private static func faviconURL(from pageURL: URL) -> URL? {
        guard var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private static func looksLikeImage(_ data: Data) -> Bool {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return true }
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.starts(with: [0x47, 0x49, 0x46]) { return true }
        if data.starts(with: [0x00, 0x00, 0x01, 0x00]) { return true }
        return false
    }

    /// Largest frame in the file (an `.ico` often holds 16, 32, and 256). Downscale only above `maxIconPixels`.
    /// Drawn with ImageIO. `NSImageRep.draw` places an `.ico` frame in the top-right of the bitmap.
    private static func renderedPNG(from data: Data) async -> RenderedIcon? {
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
        return RenderedIcon(sourceArea: pixelsWide * pixelsHigh, png: png)
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

    private static func isHTTP(_ url: URL) -> Bool {
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
