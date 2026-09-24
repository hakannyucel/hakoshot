import HakoKit

/// Settings > Screenshots "Crosshair mode" (plan §4.3, §5.4).
nonisolated enum CrosshairMode: String, Sendable, CaseIterable {
    /// Crosshair lines follow the cursor before a drag (default).
    case always
    /// Only while `⌘` is held (⌘ also disables snapping while held).
    case holdCommand
    case off
}

/// Overlay preferences (WP3.2). The Screenshots settings page (WP3.I) shows them.
extension SettingsKey where Value == Bool {
    /// "Show magnifier": loupe with zoomed pixels next to the cursor. Default on (plan §4.3).
    static var showMagnifier: SettingsKey<Bool> {
        SettingsKey("showMagnifier", default: true)
    }

    /// "Freeze screen": select on a still snapshot taken before the overlay
    /// appears (plan §4.2). Default off.
    static var freezeScreen: SettingsKey<Bool> {
        SettingsKey("freezeScreen", default: false)
    }
}

extension SettingsKey where Value == CrosshairMode {
    /// "Crosshair mode": Always / Hold ⌘ / Off, default Always (plan §4.3, §5.4).
    static var showCrosshair: SettingsKey<CrosshairMode> {
        SettingsKey("showCrosshair", default: .always)
    }
}

extension OverlayConfig {
    /// `config` with the user's overlay preferences applied (magnifier,
    /// crosshair, freeze). Callers still decide `mode`, `initialRect`, `editable`.
    func applyingUserSettings(_ settings: AppSettings = .shared) -> OverlayConfig {
        var config = self
        config.showsMagnifier = settings.value(for: .showMagnifier)
        config.crosshairMode = settings.value(for: .showCrosshair)
        config.freeze = settings.value(for: .freezeScreen)
        return config
    }
}
