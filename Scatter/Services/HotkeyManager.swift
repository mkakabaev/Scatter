import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleApp = Self("toggleApp", default: .init(.space, modifiers: [.option, .command]))
}

enum HotkeyManager {
    /// Set from AppDelegate so the hotkey can raise-or-hide using live window key state.
    @MainActor
    static var toggleHandler: (() -> Void)?

    @MainActor
    static func install() {
        KeyboardShortcuts.onKeyUp(for: .toggleApp) {
            Task { @MainActor in
                guard let toggleHandler else {
                    assertionFailure("HotkeyManager.toggleHandler must be set before the hotkey fires")
                    return
                }
                toggleHandler()
            }
        }
    }
}
