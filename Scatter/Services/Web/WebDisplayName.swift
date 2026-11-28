import Foundation

/// HTTP(S) URL labels for launcher items — usable page titles + host fallback.
/// Expects already-decoded text; lossy-decode markers are handled at the decode boundary.
enum WebDisplayName {
    /// Nil when empty or whitespace-only.
    static func usableTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let collapsed = title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return collapsed
    }

    static func of(title: String?, url: URL) -> String {
        if let title = usableTitle(title), title != url.absoluteString {
            return title
        }
        return url.host ?? url.absoluteString
    }
}

extension URL {
    var isHTTP: Bool {
        let scheme = scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }

    /// Trims whitespace; returns nil unless the string is a valid http(s) URL.
    static func httpURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.isHTTP else { return nil }
        return url
    }
}
