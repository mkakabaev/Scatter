import AppKit

/// System open panel for adding files or folders to the canvas (empty-area context menu).
enum AddItemsPanel {
    /// Returns selected URLs, or `nil` if cancelled.
    static func run() -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose files or folders to add"
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return nil }
        return panel.urls
    }
}
