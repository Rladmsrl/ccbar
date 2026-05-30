import Foundation
import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "Launch at login" toggle.
enum LaunchAtLogin {
    private enum DefaultsKey {
        static let didApplyDefaultEnabled = "launchAtLogin.didApplyDefaultEnabled"
        static let didRecordUserChoice = "launchAtLogin.didRecordUserChoice"
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func enableByDefaultIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: DefaultsKey.didApplyDefaultEnabled) == nil,
              defaults.object(forKey: DefaultsKey.didRecordUserChoice) == nil else { return }

        if apply(true) {
            defaults.set(true, forKey: DefaultsKey.didApplyDefaultEnabled)
        }
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(true, forKey: DefaultsKey.didRecordUserChoice)
        _ = apply(enabled)
    }

    private static func apply(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            return isEnabled == enabled
        } catch {
            Log.app.error("Failed to set launch-at-login to \(enabled): \(error.localizedDescription)")
            return false
        }
    }
}
