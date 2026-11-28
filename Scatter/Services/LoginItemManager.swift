import Foundation
import ServiceManagement

enum LoginItemManager {
    /// Current system registration (read-only — never registers on cold launch).
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Registers or unregisters the login item. Returns `false` on failure (caller should revert UI preference).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            NSLog("\(AppIdentity.displayName) login item error: \(error)")
            return false
        }
    }
}
