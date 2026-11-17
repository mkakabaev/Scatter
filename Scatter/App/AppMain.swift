import SwiftUI

@main
struct AppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Menu-bar / LSUIElement app: windows are owned by AppDelegate.
        Settings {
            EmptyView()
        }
    }
}
