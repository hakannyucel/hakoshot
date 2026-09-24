import CoreGraphics
import Foundation
import HakoKit

/// Quick Access settings (plan §5.3 "Quick Access" tab, §5.4 defaults, §4.12).
/// Keys live here, next to the feature, per the `AppSettings` convention.

/// Which bottom corner the card stack sits in (plan §5.4: bottom-left).
nonisolated enum QuickAccessPosition: String, Sendable, CaseIterable {
    case left
    case right
}

/// What auto-close does when the interval runs out (plan §5.4: "Save and Close").
nonisolated enum QuickAccessAutoCloseAction: String, Sendable, CaseIterable {
    case saveAndClose
    case close
}

/// What the "Save" button does (plan §5.3: Save to export location / Ask for destination).
nonisolated enum QuickAccessSaveBehavior: String, Sendable, CaseIterable {
    case exportLocation
    case askForDestination
}

extension SettingsKey where Value == QuickAccessPosition {
    static var quickAccessPosition: SettingsKey<QuickAccessPosition> {
        SettingsKey("quickAccessPosition", default: .left)
    }
}

extension SettingsKey where Value == QuickAccessAutoCloseAction {
    static var quickAccessAutoCloseAction: SettingsKey<QuickAccessAutoCloseAction> {
        SettingsKey("quickAccessAutoCloseAction", default: .saveAndClose)
    }
}

extension SettingsKey where Value == QuickAccessSaveBehavior {
    static var quickAccessSaveBehavior: SettingsKey<QuickAccessSaveBehavior> {
        SettingsKey("quickAccessSaveBehavior", default: .exportLocation)
    }
}

extension SettingsKey where Value == Bool {
    /// Show cards on the screen with the pointer ("Move to active screen", default on).
    /// Off: the screen the capture came from, else the main screen.
    static var quickAccessMoveToActiveScreen: SettingsKey<Bool> {
        SettingsKey("quickAccessMoveToActiveScreen", default: true)
    }

    static var quickAccessAutoCloseEnabled: SettingsKey<Bool> {
        SettingsKey("quickAccessAutoCloseEnabled", default: true)
    }

    /// Close the card after it was dropped somewhere (default on).
    static var quickAccessCloseAfterDragging: SettingsKey<Bool> {
        SettingsKey("quickAccessCloseAfterDragging", default: true)
    }
}

extension SettingsKey where Value == Int {
    /// Auto-close interval in seconds (default 30).
    static var quickAccessAutoCloseSeconds: SettingsKey<Int> {
        SettingsKey("quickAccessAutoCloseSeconds", default: 30)
    }
}

extension SettingsKey where Value == Double {
    /// Card width in points ("Overlay size" slider, 140–320, default 200).
    static var quickAccessCardWidth: SettingsKey<Double> {
        SettingsKey("quickAccessCardWidth", default: Double(Tokens.Size.quickAccessCardWidth))
    }
}

/// Snapshot of every Quick Access setting, read once per `show(_:)`.
nonisolated struct QuickAccessConfig: Sendable, Equatable {
    static let cardWidthRange: ClosedRange<CGFloat> = 140...320
    static let autoCloseSecondsRange: ClosedRange<Int> = 3...600
    /// Plan §4.12: at most 6 cards visible; older ones are closed (with the auto-close action).
    static let maxVisibleCards = 6

    var position: QuickAccessPosition = .left
    var moveToActiveScreen = true
    var cardWidth: CGFloat = Tokens.Size.quickAccessCardWidth
    var autoCloseEnabled = true
    var autoCloseSeconds = 30
    var autoCloseAction: QuickAccessAutoCloseAction = .saveAndClose
    var closeAfterDragging = true
    var saveBehavior: QuickAccessSaveBehavior = .exportLocation

    /// `nil` when auto-close is off.
    var autoCloseInterval: TimeInterval? {
        autoCloseEnabled ? TimeInterval(autoCloseSeconds) : nil
    }
}

extension QuickAccessConfig {
    init(settings: AppSettings) {
        let width = CGFloat(settings.value(for: .quickAccessCardWidth))
        let seconds = settings.value(for: .quickAccessAutoCloseSeconds)
        self.init(
            position: settings.value(for: .quickAccessPosition),
            moveToActiveScreen: settings.value(for: .quickAccessMoveToActiveScreen),
            cardWidth: min(max(width, Self.cardWidthRange.lowerBound), Self.cardWidthRange.upperBound),
            autoCloseEnabled: settings.value(for: .quickAccessAutoCloseEnabled),
            autoCloseSeconds: min(max(seconds, Self.autoCloseSecondsRange.lowerBound), Self.autoCloseSecondsRange.upperBound),
            autoCloseAction: settings.value(for: .quickAccessAutoCloseAction),
            closeAfterDragging: settings.value(for: .quickAccessCloseAfterDragging),
            saveBehavior: settings.value(for: .quickAccessSaveBehavior)
        )
    }
}
