import CoreGraphics
import Foundation
import HakoKit

/// Settings → Screenshots → Window Screenshots → Background (plan §4.4).
nonisolated enum WindowCaptureBackgroundKind: String, CaseIterable, Sendable {
    /// Alpha channel kept around the window and its shadow (default).
    case transparent
    /// The user's desktop wallpaper behind the window, with padding.
    case wallpaper
    /// A solid color behind the window, with padding.
    case solidColor
}

/// Window-capture `SettingsKey`s (plan §4.4, §5.4).
extension SettingsKey where Value == Bool {
    /// Keep the window's drop shadow. Default on (plan §4.4, M3 acceptance #1).
    static var windowCaptureShadow: SettingsKey<Bool> {
        SettingsKey("windowCaptureShadow", default: true)
    }
}

extension SettingsKey where Value == WindowCaptureBackgroundKind {
    /// Default: transparent (plan §4.4).
    static var windowCaptureBackground: SettingsKey<WindowCaptureBackgroundKind> {
        SettingsKey("windowCaptureBackground", default: .transparent)
    }
}

extension SettingsKey where Value == String {
    /// `#RRGGBB[AA]` for `.solidColor`. Default white (no plan value; sugg.).
    static var windowCaptureBackgroundColor: SettingsKey<String> {
        SettingsKey("windowCaptureBackgroundColor", default: "#FFFFFF")
    }
}

extension SettingsKey where Value == Double {
    /// Points around the window for wallpaper / solid backgrounds (plan §4.4:
    /// 64 pt). Ignored for transparent captures.
    static var windowCapturePadding: SettingsKey<Double> {
        SettingsKey("windowCapturePadding", default: 64)
    }
}

/// What `ScreenCaptureService.captureWindow(_:options:)` produces.
nonisolated struct WindowCaptureOptions: Sendable, Equatable {
    enum Background: Sendable, Equatable {
        case transparent
        case wallpaper
        case solid(RGBAColor)
    }

    var includesShadow: Bool = true
    var background: Background = .transparent
    /// Points on each side; only used with a non-transparent background.
    var padding: CGFloat = 64
    var showsCursor: Bool = false

    static let `default` = WindowCaptureOptions()
}

extension AppSettings {
    /// The current window-capture preferences.
    var windowCaptureOptions: WindowCaptureOptions {
        let background: WindowCaptureOptions.Background = switch value(for: .windowCaptureBackground) {
        case .transparent: .transparent
        case .wallpaper: .wallpaper
        case .solidColor: .solid(RGBAColor(hex: value(for: .windowCaptureBackgroundColor)) ?? .white)
        }
        return WindowCaptureOptions(
            includesShadow: value(for: .windowCaptureShadow),
            background: background,
            padding: CGFloat(max(0, value(for: .windowCapturePadding)))
        )
    }
}
