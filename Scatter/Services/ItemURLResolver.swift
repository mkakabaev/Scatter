import Foundation

/// Resolve a launcher item’s target URL from stored `urlString` / bookmark (launch-only; no security scope).
enum ItemURLResolver {
    struct Resolution {
        var url: URL
        /// When the item bookmark was stale, fresh `.minimalBookmark` bytes to persist.
        var refreshedBookmarkData: Data? = nil
    }

    static func resolve(_ item: LauncherItem) -> URL? {
        resolveDetailed(item)?.url
    }

    /// Prefer on-disk `urlString`; fall back to bookmark. Returns refreshed bookmark bytes when stale.
    static func resolveDetailed(_ item: LauncherItem) -> Resolution? {
        if let urlString = item.urlString {
            if urlString.hasPrefix("/"), FileManager.default.fileExists(atPath: urlString) {
                return Resolution(url: URL(fileURLWithPath: urlString))
            }
            if let url = URL(string: urlString) {
                if url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                    return Resolution(url: url)
                }
                if url.isHTTP {
                    return Resolution(url: url)
                }
                // Missing file path: fall through to bookmark (moved/renamed targets).
            }
        }
        if let bookmarkData = item.bookmarkData, let resolved = MinimalBookmark.resolve(bookmarkData) {
            return Resolution(url: resolved.url, refreshedBookmarkData: resolved.refreshedData)
        }
        return nil
    }

    static func isCodeWorkspace(_ item: LauncherItem) -> Bool {
        if let url = resolve(item) {
            return url.pathExtension.lowercased() == "code-workspace"
        }
        if let urlString = item.urlString, let url = URL(string: urlString) {
            return url.pathExtension.lowercased() == "code-workspace"
        }
        return false
    }
}
