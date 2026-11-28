import Foundation

enum LauncherItemFactory {
    static func makeItem(from url: URL, at position: CGPoint, title: String? = nil) -> LauncherItem? {
        if url.isHTTP {
            return LauncherItem(
                kind: .url,
                urlString: url.absoluteString,
                displayName: WebDisplayName.of(title: title, url: url),
                position: .init(position)
            )
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }

        let kind: LauncherItem.Kind
        if url.pathExtension.lowercased() == "app" || (isDir.boolValue && url.path.hasSuffix(".app")) {
            kind = .app
        } else if isDir.boolValue {
            kind = .folder
        } else {
            kind = .file
        }

        let bookmark = MinimalBookmark.data(for: url)

        // Files: strip extension. Folders: keep the full name (dots are not extensions).
        // Apps: Finder-style label without a trailing `.app`.
        let name: String
        switch kind {
        case .folder:
            name = url.lastPathComponent
        case .app:
            name = FileDisplayName.of(url)
        case .file:
            name = url.deletingPathExtension().lastPathComponent
        case .url:
            name = url.lastPathComponent
        }

        return LauncherItem(
            kind: kind,
            bookmarkData: bookmark,
            urlString: url.absoluteString,
            displayName: name,
            position: .init(position)
        )
    }
}
