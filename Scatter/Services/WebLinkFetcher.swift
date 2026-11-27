import AppKit
import Foundation
import ImageIO

/// Loads favicon PNG and page title for a dropped/pasted http(s) link (one shared HTML prefix fetch).
enum WebLinkFetcher {
    struct PageAssets {
        var png: Data?
        var title: String?
    }

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
    private static let manifestByteLimit = 64 * 1024
    private static let imageByteLimit = 1_500_000
    /// Largest side stored in `iconPNGData`. Sized for Settings max icon points at 2× Retina
    /// (`TileMetrics.maxIconSize * 2`), not the live slider — favicons are fetched once at drop
    /// and must stay sharp if the user later raises icon size. Bigger sources scale down; never up.
    private static let maxIconPixels = Int(TileMetrics.maxIconSize) * 2
    private static let maxDownloads = 8

    /// Favicon PNG plus page title from the same HTML fetch (`og:title` / `twitter:title` / `<title>`).
    static func fetch(for pageURL: URL) async -> PageAssets {
        guard isHTTP(pageURL) else { return PageAssets() }

        var candidates: [URL] = []
        var title: String?
        if let page = await fetchPrefix(from: pageURL, limit: htmlByteLimit) {
            if looksLikeImage(page.data), let rendered = await renderedPNG(from: page.data) {
                return PageAssets(png: rendered.png, title: nil)
            }
            if let html = decodeHTML(page.data) {
                title = pageTitle(in: html)
                // Manifest icons first: sites like ya.ru ship 512px there and only soft 192px in <link>.
                if let manifest = manifestURL(in: html, base: page.finalURL) {
                    candidates.append(contentsOf: await manifestIconURLs(from: manifest))
                }
                candidates.append(contentsOf: iconURLs(in: html, base: page.finalURL))
            }
            // Always try the dropped URL's /favicon.ico. Auth/SSO redirects change finalURL,
            // and that host's icon is often useless while the original origin still serves one.
            if let fallback = faviconURL(from: pageURL) {
                candidates.append(fallback)
            }
            // After a host change (apex → www, etc.), also try the final host.
            if !sameHost(pageURL, page.finalURL), let fallback = faviconURL(from: page.finalURL) {
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
        return PageAssets(png: best?.png, title: title)
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

    /// Decode a capped HTML prefix. A mid-stream cut can split a UTF-8 codepoint; use lossy UTF-8
    /// so early content (titles / icon links) stays valid instead of falling through to Latin-1 mojibake.
    private static func decodeHTML(_ data: Data) -> String? {
        let utf8 = String(decoding: data, as: UTF8.self)
        if utf8.contains(where: { $0 != "\u{FFFD}" }) { return utf8 }
        return String(data: data, encoding: .isoLatin1)
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

    private static func downloadManifest(_ url: URL) async -> Data? {
        guard isHTTP(url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue(
            "application/manifest+json,application/json;q=0.9,*/*;q=0.5",
            forHTTPHeaderField: "Accept"
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            guard !data.isEmpty, data.count <= manifestByteLimit else { return nil }
            return data
        } catch {
            NSLog("Manifest obtain failed: \(error)")
            return nil
        }
    }

    /// Prefer Open Graph / Twitter title, then `<title>`. Decodes common HTML entities.
    private static func pageTitle(in html: String) -> String? {
        if let og = metaContent(in: html, property: "og:title") { return og }
        if let twitter = metaContent(in: html, name: "twitter:title") { return twitter }
        return htmlTitle(in: html)
    }

    private static func metaContent(in html: String, property: String? = nil, name: String? = nil) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<meta\b(?:[^>"']|"[^"]*"|'[^']*')*>"#,
            options: [.caseInsensitive]
        ) else { return nil }

        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: match.range)
            let attrs = attributes(in: tag)
            if let property {
                guard attrs["property"]?.caseInsensitiveCompare(property) == .orderedSame else { continue }
            }
            if let name {
                guard attrs["name"]?.caseInsensitiveCompare(name) == .orderedSame else { continue }
            }
            guard let content = attrs["content"] else { continue }
            let decoded = decodeHTMLEntities(content)
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
            if !decoded.isEmpty { return decoded }
        }
        return nil
    }

    private static func htmlTitle(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"<title\b[^>]*>(.*?)</title>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return nil }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let raw = ns.substring(with: match.range(at: 1))
        let decoded = decodeHTMLEntities(raw)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return decoded.isEmpty ? nil : decoded
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        // Numeric entities: &#123; / &#x1F4A9;
        if let regex = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) {
            let ns = result as NSString
            let matches = regex.matches(in: result, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let body = ns.substring(with: match.range(at: 1))
                let scalar: Unicode.Scalar?
                if body.lowercased().hasPrefix("x") {
                    scalar = UInt32(body.dropFirst(), radix: 16).flatMap(Unicode.Scalar.init)
                } else {
                    scalar = UInt32(body).flatMap(Unicode.Scalar.init)
                }
                guard let scalar else { continue }
                result = (result as NSString).replacingCharacters(in: match.range, with: String(scalar))
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
            let attrs = attributes(in: tag)
            guard let rel = attrs["rel"]?.lowercased() else { continue }
            let tokens = rel.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard tokens.contains("manifest"), let href = attrs["href"] else { continue }
            let decoded = href
                .replacingOccurrences(of: "&amp;", with: "&")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !decoded.isEmpty, !decoded.lowercased().hasPrefix("data:") else { continue }
            guard let resolved = URL(string: decoded, relativeTo: base)?.absoluteURL, isHTTP(resolved) else {
                continue
            }
            return resolved
        }
        return nil
    }

    /// Icons from a web app manifest, largest declared size first. Skips SVG and monochrome entries.
    private static func manifestIconURLs(from manifestURL: URL) async -> [URL] {
        guard let data = await downloadManifest(manifestURL) else { return [] }
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
            guard let resolved = URL(string: decoded, relativeTo: manifestURL)?.absoluteURL, isHTTP(resolved) else {
                continue
            }
            let sizes = icon["sizes"] as? String ?? ""
            refs.append(IconRef(url: resolved, declaredSize: largestSize(sizes)))
        }
        return orderedIconURLs(refs)
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

    private static func sameHost(_ a: URL, _ b: URL) -> Bool {
        guard let left = a.host?.lowercased(), let right = b.host?.lowercased() else { return false }
        return left == right
    }
}
