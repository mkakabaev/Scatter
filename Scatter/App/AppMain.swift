import SwiftUI

@main
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar / LSUIElement app: windows are owned by AppDelegate.
        // SwiftUI Settings is a required Scene stub only — never present it.
        // Replacing .appSettings keeps ⌘, / Settings… on the AppKit window.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettingsFromMenu()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
