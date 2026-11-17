import AppKit

enum OpenWithPanel {
    struct Result {
        var applicationURL: URL
        var alwaysOpenIn: Bool
    }

    /// App picker with an “Always open in” checkbox accessory.
    static func run(message: String = "Choose an app to open this item") -> Result? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Choose"
        panel.message = message

        let checkbox = NSButton(checkboxWithTitle: "Always open in", target: nil, action: nil)
        checkbox.state = .off
        checkbox.setButtonType(.switch)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 28))
        checkbox.frame = NSRect(x: 0, y: 2, width: 280, height: 24)
        container.addSubview(checkbox)
        panel.accessoryView = container
        panel.isAccessoryViewDisclosed = true

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return Result(applicationURL: url, alwaysOpenIn: checkbox.state == .on)
    }

    static func displayName(forApplicationAt url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func displayName(bundleID: String?, bookmark: Data?) -> String? {
        if let bookmark {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return displayName(forApplicationAt: url)
            }
        }
        if let bundleID,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return displayName(forApplicationAt: url)
        }
        return nil
    }
}
