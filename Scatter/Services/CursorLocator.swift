import AppKit

enum CursorLocator {
    
    static private var defaultAppUrl =  URL(fileURLWithPath: "/Applications/Cursor.app")
    
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
        let app = defaultAppUrl
        if FileManager.default.fileExists(atPath: app.path) {
            return Bundle(url: app)?.bundleIdentifier ?? candidates[0]
        }
        return nil
    }

    static var applicationURL: URL? {
        if let bid = bundleIdentifier {
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid)
        }
        let app = defaultAppUrl
        return FileManager.default.fileExists(atPath: app.path) ? app : nil
    }
}
