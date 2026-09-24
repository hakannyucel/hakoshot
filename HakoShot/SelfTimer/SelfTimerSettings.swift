import HakoKit

/// Settings > Screenshots > "Self-timer" (plan §4.14, §5.4).
enum SelfTimerSettings {
    /// Choices offered in Settings (plan §5.4: 3 / 5 / 10 s).
    static let intervalChoices = [3, 5, 10]

    /// The stored interval, clamped to 1…60 s so a hand-edited default can't hang a capture.
    static func interval(_ settings: AppSettings = .shared) -> Int {
        min(max(settings.value(for: .selfTimerSeconds), 1), 60)
    }
}

extension SettingsKey where Value == Int {
    /// Countdown before a self-timer capture, in seconds. Default 5 (plan §5.4).
    static var selfTimerSeconds: SettingsKey<Int> {
        SettingsKey("selfTimerSeconds", default: 5)
    }
}
