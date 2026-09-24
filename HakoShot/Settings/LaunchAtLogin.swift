import os
import Foundation
import Observation
import ServiceManagement

/// Settings > General "Launch at login" (plan §5.3, M7 acceptance #5).
/// No UserDefaults key: `SMAppService.mainApp.status` is the source of truth,
/// re-read when the page appears.
@Observable
final class LaunchAtLogin {
    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var lastError: String?

    /// On, or waiting for approval in System Settings > Login Items.
    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        lastError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            lastError = error.localizedDescription
            Log.settings.error("launch at login \(enabled) failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
        Log.settings.notice("launch at login status \(String(describing: self.status), privacy: .public)")
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
