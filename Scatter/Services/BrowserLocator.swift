import AppKit
import UniformTypeIdentifiers

enum BrowserLocator {
    /// Apps that handle both `https:` and HTML — a practical installed-browser list.
    static var installedBrowsers: [URL] {
        guard let httpsURL = URL(string: "https:") else { return [] }
        let https = Set(NSWorkspace.shared.urlsForApplications(toOpen: httpsURL))
        let html = Set(NSWorkspace.shared.urlsForApplications(toOpen: .html))
        let defaultBrowser = NSWorkspace.shared.urlForApplication(toOpen: httpsURL)
        return Array(https.intersection(html)).sorted { a, b in
            if a.standardizedFileURL == defaultBrowser?.standardizedFileURL { return true }
            if b.standardizedFileURL == defaultBrowser?.standardizedFileURL { return false }
            let nameA = FileManager.default.displayName(atPath: a.path)
            let nameB = FileManager.default.displayName(atPath: b.path)
            return nameA.localizedCaseInsensitiveCompare(nameB) == .orderedAscending
        }
    }
}
