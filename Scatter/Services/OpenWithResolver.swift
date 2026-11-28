import AppKit

enum OpenWithResolver {
    struct Resolved: Equatable {
        var url: URL
        var displayName: String
        /// When the Open With bookmark was stale, fresh bytes to persist.
        var refreshedBookmarkData: Data? = nil
    }

    /// Saved Open With when the app still exists on disk.
    static func resolve(for item: LauncherItem) -> Resolved? {
        if let bookmark = item.openWithBookmarkData,
           let resolved = MinimalBookmark.resolve(bookmark),
           applicationExists(at: resolved.url) {
            return Resolved(
                url: resolved.url,
                displayName: FileDisplayName.of(resolved.url),
                refreshedBookmarkData: resolved.refreshedData
            )
        }
        if let bundleID = item.openWithBundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           applicationExists(at: url) {
            return resolved(url)
        }
        return nil
    }

    /// One-shot Open With app when it still exists on disk.
    static func resolve(applicationAt url: URL) -> Resolved? {
        applicationExists(at: url) ? resolved(url) : nil
    }

    private static func applicationExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private static func resolved(_ url: URL) -> Resolved {
        Resolved(url: url, displayName: FileDisplayName.of(url))
    }
}
