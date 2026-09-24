import Foundation
import HakoKit

/// Settings > Annotate keys (plan §5.3, §5.4 annotation defaults).
extension SettingsKey where Value == String {
    /// `#RRGGBB` for new annotations (all tools but the highlighter). Default pink `#FF375F`.
    static var annotateDefaultColor: SettingsKey<String> {
        SettingsKey("annotateDefaultColor", default: String(RGBAColor.defaultAnnotation.hexString.prefix(7)))
    }

    /// JSON `ToolSettings` of the last editor session ("Remember last used").
    static var annotateLastToolSettings: SettingsKey<String> {
        SettingsKey("annotateLastToolSettings", default: "")
    }
}

extension SettingsKey where Value == Int {
    /// 0-based `StrokeWidthPreset` index. Default 2 (6 pt).
    static var annotateStrokeWidthIndex: SettingsKey<Int> {
        SettingsKey("annotateStrokeWidthIndex", default: StrokeWidthPreset.defaultIndex)
    }

    /// 0-based `TextSizePreset` index. Default 3 (30 pt).
    static var annotateTextSizeIndex: SettingsKey<Int> {
        SettingsKey("annotateTextSizeIndex", default: TextSizePreset.defaultIndex)
    }
}

extension SettingsKey where Value == Bool {
    /// Shadow on new shapes, arrows and text. Default on (plan §5.4).
    static var annotateShadow: SettingsKey<Bool> {
        SettingsKey("annotateShadow", default: true)
    }

    /// Start each editor with the options used last instead of the defaults. Default on.
    static var annotateRememberLastUsed: SettingsKey<Bool> {
        SettingsKey("annotateRememberLastUsed", default: true)
    }
}

extension SettingsKey where Value == ArrowStyle {
    static var annotateArrowStyle: SettingsKey<ArrowStyle> {
        SettingsKey("annotateArrowStyle", default: .standard)
    }
}

extension SettingsKey where Value == TextStyle {
    static var annotateTextStyle: SettingsKey<TextStyle> {
        SettingsKey("annotateTextStyle", default: .standard)
    }
}

extension SettingsKey where Value == CounterStyle {
    static var annotateCounterStyle: SettingsKey<CounterStyle> {
        SettingsKey("annotateCounterStyle", default: .filledCircle)
    }
}

extension SettingsKey where Value == RedactionMethod {
    static var annotateRedactionMethod: SettingsKey<RedactionMethod> {
        SettingsKey("annotateRedactionMethod", default: .pixelate)
    }
}

/// The editor's starting `ToolSettings`, from Settings > Annotate.
///
/// Editor wiring (`EditorViewModel.init`):
/// `EditorStore(document: document, toolSettings: AnnotateDefaults.initialToolSettings(settings))`
/// and after each `.setToolSettings`: `AnnotateDefaults.remember(store.toolSettings, settings: settings)`.
enum AnnotateDefaults {
    /// The defaults chosen on the Annotate page.
    static func configured(_ settings: AppSettings) -> ToolSettings {
        var tools = ToolSettings()
        if let color = RGBAColor(hex: settings.value(for: .annotateDefaultColor)) {
            tools.color = color
        }
        tools.strokePresetIndex = clamp(settings.value(for: .annotateStrokeWidthIndex), count: StrokeWidthPreset.points.count)
        tools.textSizePresetIndex = clamp(settings.value(for: .annotateTextSizeIndex), count: TextSizePreset.points.count)
        tools.shadow = settings.value(for: .annotateShadow)
        tools.arrowStyle = settings.value(for: .annotateArrowStyle)
        tools.textStyle = settings.value(for: .annotateTextStyle)
        tools.counterStyle = settings.value(for: .annotateCounterStyle)
        tools.redactionMethod = settings.value(for: .annotateRedactionMethod)
        return tools
    }

    /// Last used options when "Remember last used" is on and some were
    /// stored, else `configured`.
    static func initialToolSettings(_ settings: AppSettings) -> ToolSettings {
        if settings.value(for: .annotateRememberLastUsed), let last = decode(settings.value(for: .annotateLastToolSettings)) {
            return last
        }
        return configured(settings)
    }

    /// Stores the editor's current options for the next editor (no-op when
    /// "Remember last used" is off).
    static func remember(_ tools: ToolSettings, settings: AppSettings) {
        guard settings.value(for: .annotateRememberLastUsed) else { return }
        settings.set(encode(tools), for: .annotateLastToolSettings)
    }

    /// Forgets the remembered options (the next editor uses the defaults).
    static func forgetLastUsed(settings: AppSettings) {
        settings.set("", for: .annotateLastToolSettings)
    }

    static func encode(_ tools: ToolSettings) -> String {
        guard let data = try? JSONEncoder().encode(tools) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> ToolSettings? {
        guard let data = json.data(using: .utf8), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(ToolSettings.self, from: data)
    }

    private static func clamp(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count - 1)
    }
}
