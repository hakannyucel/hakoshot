import AppKit
import Foundation
import HakoKit
import os

/// Pin `SettingsKey`s (plan §5.3 Advanced tab "Pin: rounded corners (on), shadow (off),
/// border (off)" and §5.4 "Pin | Köşe açık, gölge/kenarlık kapalı, opaklık %100").
extension SettingsKey where Value == Bool {
    static var pinRoundedCorners: SettingsKey<Bool> {
        SettingsKey("pinRoundedCorners", default: true)
    }

    static var pinShowShadow: SettingsKey<Bool> {
        SettingsKey("pinShowShadow", default: false)
    }

    static var pinShowBorder: SettingsKey<Bool> {
        SettingsKey("pinShowBorder", default: false)
    }
}

extension SettingsKey where Value == Double {
    /// Opacity a new pin starts with, 0.1...1. Default 1 (plan §5.4).
    static var pinDefaultOpacity: SettingsKey<Double> {
        SettingsKey("pinDefaultOpacity", default: 1.0)
    }
}

/// Appearance snapshot read once when a pin is created.
struct PinAppearance: Equatable {
    var roundedCorners = true
    var showsShadow = false
    var showsBorder = false
    var opacity: Double = 1

    init(roundedCorners: Bool = true, showsShadow: Bool = false, showsBorder: Bool = false, opacity: Double = 1) {
        self.roundedCorners = roundedCorners
        self.showsShadow = showsShadow
        self.showsBorder = showsBorder
        self.opacity = PinGeometry.clampOpacity(opacity)
    }

    init(settings: AppSettings) {
        self.init(
            roundedCorners: settings.value(for: .pinRoundedCorners),
            showsShadow: settings.value(for: .pinShowShadow),
            showsBorder: settings.value(for: .pinShowBorder),
            opacity: settings.value(for: .pinDefaultOpacity)
        )
    }
}

/// Pin interaction constants (visual values are in `Tokens.Pin`).
nonisolated enum PinInteraction {
    /// Resize hit band along the window edge (sugg.).
    static let resizeEdgeBand: CGFloat = 6
    /// Zoom multiplier for ⌘= / ⌘- (sugg.).
    static let keyboardZoomStep: CGFloat = 1.25
    /// Opacity change per precise (trackpad) scroll point and per wheel line (sugg.).
    static let opacityPerScrollPoint: Double = 0.004
    static let opacityPerScrollLine: Double = 0.05
    /// Zoom change per precise ⌘-scroll point and per wheel line (sugg.).
    static let zoomPerScrollPoint: CGFloat = 0.01
    static let zoomPerScrollLine: CGFloat = 0.1
}

extension Log {
    static let pin = Logger(subsystem: subsystem, category: "pin")
}
