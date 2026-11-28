import Foundation

/// Launch-only bookmarks: `.minimalBookmark` create, no security scope (avoids App Management TCC).
enum MinimalBookmark {
    struct Resolution {
        var url: URL
        /// Fresh bookmark bytes when the system reported the input as stale; otherwise nil.
        var refreshedData: Data?
    }

    static func data(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: [.minimalBookmark],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    static func resolve(_ data: Data) -> Resolution? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else {
            return nil
        }
        let refreshed = stale ? Self.data(for: url) : nil
        return Resolution(url: url, refreshedData: refreshed)
    }
}
