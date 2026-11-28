import AppKit
import UniformTypeIdentifiers

enum BrowserLocator {
    struct Browser: Equatable {
        var url: URL
        var displayName: String
        var isDefault: Bool
    }

    /// Apps that handle both `https:` and HTML — a practical installed-browser list.
    /// System default first, then A–Z by display name. URLs are standardized.
    static var installedBrowsers: [Browser] {
        guard let httpsURL = URL(string: "https:") else { return [] }
        let https = Set(NSWorkspace.shared.urlsForApplications(toOpen: httpsURL))
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: .html))
        let defaultURL = NSWorkspace.shared.urlForApplication(toOpen: httpsURL)?.standardizedFileURL
        return https.intersection(html).map { app in
            let url = app.standardizedFileURL
            return Browser(
                url: url,
                displayName: FileDisplayName.of(url),
                isDefault: url == defaultURL
            )
        }
        .sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }
}
