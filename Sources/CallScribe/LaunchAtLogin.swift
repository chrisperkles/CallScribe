import Foundation
import ServiceManagement

enum LaunchAtLogin {
    private static let firstRunKey = "didConfigureLaunchAtLogin"

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The app is a background recorder — it's only useful if it's already there
    /// when you need it, so it opts in by default and the user can opt out.
    static func enableOnFirstRun() {
        guard !UserDefaults.standard.bool(forKey: firstRunKey) else { return }
        UserDefaults.standard.set(true, forKey: firstRunKey)
        setEnabled(true)
    }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
        } catch {
            NSLog("CallScribe: launch-at-login (\(enabled)) failed: \(error)")
        }
    }
}
