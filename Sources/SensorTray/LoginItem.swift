import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (only meaningful when running as the .app).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns the resulting state, which may differ from the request if
    /// macOS refused (e.g. running the bare binary from .build).
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("SensorTray: login item change failed: \(error)")
        }
        return isEnabled
    }
}
