import HakoKit

/// Capture options (WP3.3, plan §4.5, §4.6, §5.3, §5.4).
extension SettingsKey where Value == Bool {
    /// Settings > General "Hide desktop icons while capturing": leave Finder's
    /// icon windows and desktop widgets out of every capture
    /// (`DesktopIconFilter`). Default off (plan §4.5, risk R4).
    static var hideDesktopIconsWhileCapturing: SettingsKey<Bool> {
        SettingsKey("hideDesktopIconsWhileCapturing", default: false)
    }

    /// Settings > Screenshots "Show cursor": draw the mouse cursor into
    /// screenshots. Default off (plan §5.4 "İmleç yakalama: Kapalı").
    static var captureCursor: SettingsKey<Bool> {
        SettingsKey("captureCursor", default: false)
    }

    /// Settings > Screenshots "Crop notch area in fullscreen captures".
    /// Default on (plan §4.6).
    static var cropNotch: SettingsKey<Bool> {
        SettingsKey("cropNotch", default: true)
    }
}
