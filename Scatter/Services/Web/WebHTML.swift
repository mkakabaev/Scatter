import Foundation

/// HTML prefix decode + lightweight title / meta / attribute parsing for web-link enrichment.
enum WebHTML {
    /// U+FFFD — inserted when bytes were decoded with the wrong charset (or a truncated codepoint).
    private static let replacementCharacter: Character = "\u{FFFD}"

    private static func hasReplacementCharacters(_ string: String) -> Bool {
        string.contains(replacementCharacter)
    }

    private static func replacementCount(in string: String) -> Int {
        string.reduce(0) { $0 + ($1 == replacementCharacter ? 1 : 0) }
    }

    /// Decode a capped HTML prefix. Prefer `<meta charset>` then `Content-Type`; otherwise lossy UTF-8.
    /// A mid-stream cut can split a UTF-codepoint (a few trailing U+FFFD is fine).
    static func decode(_ data: Data, contentTypeCharset: String? = nil) -> String? {
        var tried: Set<String> = []
        for name in [metaCharset(in: data), contentTypeCharset].compactMap({ $0 }) {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard tried.insert(key).inserted,
                  let encoding = stringEncoding(fromCharset: name),
                  let decoded = String(data: data, encoding: encoding) else { continue }
            return decoded
        }

        let utf8 = String(decoding: data, as: UTF8.self)
        let replacements = replacementCount(in: utf8)
        // Truncation may leave 1–3 replacement chars at the tail; more implies wrong encoding.
        if replacements <= 3, replacements < utf8.count {
            return utf8
        }
        if let decoded = String(data: data, encoding: .windowsCP1251) {
            return decoded
        }
        return String(data: data, encoding: .isoLatin1)
    }

    /// Prefer `<title>` (browser tab title), then Open Graph / Twitter. Decodes common HTML entities.
    /// Drops titles that still contain U+FFFD (wrong encoding) so the host label stays until a good fetch.
    static func pageTitle(in html: String) -> String? {
        let raw = htmlTitle(in: html)
            ?? metaContent(in: html, property: "og:title")
            ?? metaContent(in: html, name: "twitter:title")
        guard let raw, !hasReplacementCharacters(raw) else { return nil }
        return raw
    }

    static func metaContent(in html: String, property: String? = nil, name: String? = nil) -> String? {
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

    static func attributes(in tag: String) -> [String: String] {
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

    // MARK: - Private

    private static func metaCharset(in data: Data) -> String? {
        // Charset names are ASCII; scan a small prefix without committing to a full decode.
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        if let regex = try? NSRegularExpression(
            pattern: #"<meta\b[^>]*\bcharset\s*=\s*["']?\s*([A-Za-z0-9._-]+)"#,
            options: [.caseInsensitive]
        ) {
            let ns = head as NSString
            if let match = regex.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        if let regex = try? NSRegularExpression(
            pattern: #"<meta\b[^>]*http-equiv\s*=\s*["']?\s*content-type["']?[^>]*content\s*=\s*["'][^"']*charset\s*=\s*([A-Za-z0-9._-]+)"#,
            options: [.caseInsensitive]
        ) {
            let ns = head as NSString
            if let match = regex.firstMatch(in: head, range: NSRange(location: 0, length: ns.length)),
               match.numberOfRanges > 1 {
                return ns.substring(with: match.range(at: 1))
            }
        }
        return nil
    }

    private static func stringEncoding(fromCharset charset: String) -> String.Encoding? {
        switch charset.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "utf-8", "utf8": return .utf8
        case "windows-1251", "cp1251", "cp-1251": return .windowsCP1251
        case "iso-8859-1", "latin1", "latin-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        default: return nil
        }
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
}
