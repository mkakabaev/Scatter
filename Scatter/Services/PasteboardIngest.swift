import AppKit

/// One pasteboard parse for Finder / browser / editor drop and ⌘V.
struct PasteboardContents {

    struct Item {
        var url: URL
        /// `public.url-name` for http(s); nil for files / folders / apps.
        var title: String?
    }

    var items: [Item]

    var isEmpty: Bool { items.isEmpty }

    fileprivate static func untitled(_ urls: [URL]) -> PasteboardContents {
        PasteboardContents(items: urls.map { .init(url: $0, title: nil) })
    }
}

enum PasteboardIngest {
    /// Prefer on-disk file URLs; otherwise VS Code/Cursor `code/file-list`; otherwise http(s); otherwise any URL.
    static func read(from pasteboard: NSPasteboard) -> PasteboardContents {
        if let files = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !files.isEmpty {
            let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
            // File URLs were offered: never fall through to text/http when all are missing.
            return .untitled(existing)
        }

        // VS Code / Cursor Explorer copy: private type with newline-separated URI strings.
        // Readable at pasteboard level even when macOS stores it under a dyn. UTI on the item.
        // Same as native file URLs: missing paths → empty (beep), never fall through to http(s).
        if let codeList = urlsFromVSCodeFileList(on: pasteboard) {
            let existing = codeList.filter { FileManager.default.fileExists(atPath: $0.path) }
            return .untitled(existing)
        }

        if let link = webLink(on: pasteboard) {
            return link
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], !urls.isEmpty {
            // Same missing-path rule as the file-URL-only branch: drop absent files; keep non-files.
            let kept = urls.filter { url in
                !url.isFileURL || FileManager.default.fileExists(atPath: url.path)
            }
            if urls.contains(where: \.isFileURL) {
                return .untitled(kept)
            }
            if !kept.isEmpty {
                return .untitled(kept)
            }
        }

        // Last resort: raw public.file-url / public.url strings on the pasteboard.
        if let paths = pasteboard.propertyList(forType: .fileURL) as? [String] {
            let urls = paths.compactMap { URL(string: $0) ?? URL(fileURLWithPath: $0) }
            if !urls.isEmpty {
                let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
                return .untitled(existing)
            }
        }
        return PasteboardContents(items: [])
    }

    private static func webLink(on pasteboard: NSPasteboard) -> PasteboardContents? {
        guard let url = webURL(on: pasteboard) else { return nil }
        let title = WebDisplayName.usableTitle(pasteboard.string(forType: urlNameType))
        return PasteboardContents(items: [.init(url: url, title: title)])
    }

    private static let urlNameType = NSPasteboard.PasteboardType("public.url-name")
    /// VS Code / Cursor Explorer file copy (Electron `clipboard.writeBuffer("code/file-list", …)`).
    private static let vsCodeFileListType = NSPasteboard.PasteboardType("code/file-list")

    private static func urlsFromVSCodeFileList(on pasteboard: NSPasteboard) -> [URL]? {
        guard let data = pasteboard.data(forType: vsCodeFileListType),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            return nil
        }
        let urls = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { URL(string: String($0)) }
        return urls.isEmpty ? nil : urls
    }

    private static func webURL(on pasteboard: NSPasteboard) -> URL? {
        if let string = pasteboard.string(forType: .URL), let url = URL.httpURL(from: string) {
            return url
        }
        if let data = pasteboard.data(forType: .URL) {
            if let string = String(data: data, encoding: .utf8), let url = URL.httpURL(from: string) {
                return url
            }
            if let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? String,
               let url = URL.httpURL(from: plist) {
                return url
            }
            if let url = URL(dataRepresentation: data, relativeTo: nil), url.isHTTP {
                return url
            }
        }
        // Browser address-bar / plain Copy often puts only UTF-8 text on the clipboard.
        if let string = pasteboard.string(forType: .string), let url = URL.httpURL(from: string) {
            return url
        }
        return nil
    }
}
