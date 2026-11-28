import Foundation

/// Loads favicon PNG and page title for a dropped/pasted http(s) link (one shared HTML prefix fetch).
enum WebLinkFetcher {
    struct PageAssets {
        var png: Data?
        var title: String?
    }

    /// Favicon PNG plus page title from the same HTML fetch (`<title>` / `og:title` / `twitter:title`).
    static func fetch(for pageURL: URL) async -> PageAssets {
        guard pageURL.isHTTP else { return PageAssets() }
        if Task.isCancelled { return PageAssets() }

        var title: String?
        var candidates: [URL] = []

        if let page = await WebLinkHTTP.fetchPrefix(from: pageURL, limit: WebLinkHTTP.htmlByteLimit) {
            if Task.isCancelled { return PageAssets() }
            if WebFavicon.looksLikeImage(page.data), let rendered = await WebFavicon.renderedPNG(from: page.data) {
                return PageAssets(png: rendered.png, title: nil)
            }
            let html = WebHTML.decode(page.data, contentTypeCharset: page.charset)
            if let html {
                title = WebHTML.pageTitle(in: html)
            }
            candidates = await WebFavicon.iconCandidates(
                html: html,
                pageURL: pageURL,
                finalURL: page.finalURL
            )
        } else {
            candidates = await WebFavicon.iconCandidates(
                html: nil,
                pageURL: pageURL,
                finalURL: pageURL
            )
        }

        var seen = Set<String>()
        var best: WebFavicon.RenderedIcon?
        var downloads = 0
        for candidate in candidates {
            if Task.isCancelled { return PageAssets() }
            guard seen.insert(candidate.absoluteString).inserted else { continue }
            guard downloads < WebFavicon.maxDownloads else { break }
            downloads += 1
            guard let data = await WebLinkHTTP.downloadImage(candidate) else { continue }
            if Task.isCancelled { return PageAssets() }
            guard let rendered = await WebFavicon.renderedPNG(from: data) else { continue }
            if best == nil || rendered.sourceArea > best!.sourceArea {
                best = rendered
            }
            // Good enough for Settings max @2× (and the 512 floor) — skip weaker leftovers.
            if let best, best.sourceSide >= WebFavicon.maxIconPixels { break }
        }
        return PageAssets(png: best?.png, title: title)
    }
}
