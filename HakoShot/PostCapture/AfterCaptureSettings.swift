import Foundation
import HakoKit

/// Settings > General > "After capture" (plan §5.3, §5.4): what happens to a
/// capture with no explicit `PostCaptureAction` override. These
/// are independent checkboxes; any combination is allowed.
///
/// Save and Copy reuse the M1 keys `outputSaveToDiskOnCapture` /
/// `outputCopyToClipboardOnCapture` (see `OutputSettings.swift`), whose
/// defaults are now the plan's (off): saving happens from Quick Access or its
/// auto-close, like the macOS screenshot thumbnail.
extension SettingsKey where Value == Bool {
    /// Show a Quick Access card. Default on.
    static var afterCaptureShowQuickAccess: SettingsKey<Bool> {
        SettingsKey("afterCaptureShowQuickAccess", default: true)
    }

    /// Open the annotation editor. Default off. The editor arrives in M4; until
    /// then this is ignored (logged).
    static var afterCaptureOpenEditor: SettingsKey<Bool> {
        SettingsKey("afterCaptureOpenEditor", default: false)
    }

    /// Pin the capture to the screen. Default off.
    static var afterCapturePin: SettingsKey<Bool> {
        SettingsKey("afterCapturePin", default: false)
    }
}

/// Snapshot of the after-capture checkboxes, read once per routed capture.
nonisolated struct AfterCaptureConfig: Sendable, Equatable {
    var showQuickAccess = true
    var copyToClipboard = false
    var saveToDisk = false
    var openEditor = false
    var pin = false

    /// Plan §5.4 defaults.
    static let `default` = AfterCaptureConfig()
}

extension AfterCaptureConfig {
    init(settings: AppSettings) {
        self.init(
            showQuickAccess: settings.value(for: .afterCaptureShowQuickAccess),
            copyToClipboard: settings.value(for: .outputCopyToClipboardOnCapture),
            saveToDisk: settings.value(for: .outputSaveToDiskOnCapture),
            openEditor: settings.value(for: .afterCaptureOpenEditor),
            pin: settings.value(for: .afterCapturePin)
        )
    }
}
