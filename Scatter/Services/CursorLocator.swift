import AppKit

enum CursorLocator {
    private static let defaultAppURL = URL(fileURLWithPath: "/Applications/Cursor.app")

    static var bundleIdentifier: String? {
        let candidates = [
            "com.todesktop.230313mzl4w4u92",
            "com.cursor.Cursor"
        ]
        for bid in candidates {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) != nil {
                return bid
            }
        }
        if FileManager.default.fileExists(atPath: defaultAppURL.path) {
            return Bundle(url: defaultAppURL)?.bundleIdentifier ?? candidates[0]
        }
        return nil
    }

    static var applicationURL: URL? {
        if let bid = bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            return url
        }
        return FileManager.default.fileExists(atPath: defaultAppURL.path) ? defaultAppURL : nil
    }
}
