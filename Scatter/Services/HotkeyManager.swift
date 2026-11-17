import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleApp = Self("toggleApp", default: .init(.space, modifiers: [.option, .command]))
}

enum HotkeyManager {
    /// Set from AppDelegate so the hotkey can raise-or-hide using live window key state.
    @MainActor
    static var toggleHandler: (() -> Void)?

    @MainActor
    static func install(store: AppStore) {
        KeyboardShortcuts.onKeyUp(for: .toggleApp) {
            Task { @MainActor in
                if let toggleHandler {
                    toggleHandler()
                } else {
                    store.toggleMainWindow()
                }
            }
        }
    }
}
