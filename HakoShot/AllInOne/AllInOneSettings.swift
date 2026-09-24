import CoreGraphics
import HakoKit

extension SettingsKey where Value == Bool {
    /// All-In-One opens with the last selection so a retake is one keypress
    /// away. Default on (plan §4.14).
    static var allInOneRemembersSelection: SettingsKey<Bool> {
        SettingsKey("allInOneRemembersSelection", default: true)
    }
}

extension SettingsKey where Value == String {
    /// Last All-In-One selection, `"x,y,width,height"` in Quartz global points; empty = none.
    static var allInOneLastSelection: SettingsKey<String> {
        SettingsKey("allInOneLastSelection", default: "")
    }
}

enum AllInOneSettings {
    /// The rect All-In-One should start with, or `nil` (setting off / nothing stored).
    static func rememberedSelection(_ settings: AppSettings = .shared) -> GlobalRect? {
        guard settings.value(for: .allInOneRemembersSelection) else { return nil }
        return decode(settings.value(for: .allInOneLastSelection))
    }

    static func remember(_ rect: GlobalRect, _ settings: AppSettings = .shared) {
        settings.set(encode(rect), for: .allInOneLastSelection)
    }

    static func encode(_ rect: GlobalRect) -> String {
        "\(rect.minX),\(rect.minY),\(rect.width),\(rect.height)"
    }

    static func decode(_ text: String) -> GlobalRect? {
        let parts = text.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 4, parts[2] > 0, parts[3] > 0 else { return nil }
        return GlobalRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
    }
}
