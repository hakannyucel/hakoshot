import Foundation
import HakoKit
import os

/// Auto-scroll speed (Settings > Screenshots > Scrolling, plan §4.8).
/// Each step scrolls a fraction of the selection's height (width when
/// horizontal); the plan's default step is 35 %.
nonisolated enum ScrollingAutoScrollSpeed: String, Sendable, CaseIterable {
    case slow
    case normal
    case fast

    /// Step size as a fraction of the visible content along the axis.
    var stepFraction: Double {
        switch self {
        case .slow: 0.2
        case .normal: 0.35
        case .fast: 0.5
        }
    }

    /// Extra pause after a step's frame was stitched, before the next step.
    var pauseBetweenSteps: Duration {
        switch self {
        case .slow: .milliseconds(250)
        case .normal: .milliseconds(60)
        case .fast: .zero
        }
    }

    var title: String {
        switch self {
        case .slow: "Slow"
        case .normal: "Normal"
        case .fast: "Fast"
        }
    }
}

/// Scrolling capture preferences (WP6.2). A settings page can show them as
/// rows; the flow reads them once per session.
extension SettingsKey where Value == Bool {
    /// Start capturing right after the area is selected ("Scroll to capture"
    /// hint, plan §4.8 flow). Off: a "Start Capture" button waits first.
    static var scrollingStartAutomatically: SettingsKey<Bool> {
        SettingsKey("scrollingStartAutomatically", default: true)
    }

    /// When auto-scroll reaches the end of the content (3 unchanged steps),
    /// finish the capture like "Done" instead of only stopping the scrolling.
    static var scrollingFinishAtContentEnd: SettingsKey<Bool> {
        SettingsKey("scrollingFinishAtContentEnd", default: true)
    }
}

extension SettingsKey where Value == ScrollingAutoScrollSpeed {
    static var scrollingAutoScrollSpeed: SettingsKey<ScrollingAutoScrollSpeed> {
        SettingsKey("scrollingAutoScrollSpeed", default: .normal)
    }
}

extension SettingsKey where Value == Int {
    /// Length cap of the stitched image in pixels (plan §5.4: 32,000 px).
    static var scrollingMaximumLength: SettingsKey<Int> {
        SettingsKey("scrollingMaximumLength", default: 32_000)
    }
}

/// Values the scrolling flow needs, read once per session.
nonisolated struct ScrollingOptions: Sendable, Equatable {
    var startAutomatically = true
    var finishAtContentEnd = true
    var autoScrollSpeed: ScrollingAutoScrollSpeed = .normal
    var maximumLength = 32_000

    init(
        startAutomatically: Bool = true,
        finishAtContentEnd: Bool = true,
        autoScrollSpeed: ScrollingAutoScrollSpeed = .normal,
        maximumLength: Int = 32_000
    ) {
        self.startAutomatically = startAutomatically
        self.finishAtContentEnd = finishAtContentEnd
        self.autoScrollSpeed = autoScrollSpeed
        self.maximumLength = maximumLength
    }
}

extension AppSettings {
    var scrollingOptions: ScrollingOptions {
        ScrollingOptions(
            startAutomatically: value(for: .scrollingStartAutomatically),
            finishAtContentEnd: value(for: .scrollingFinishAtContentEnd),
            autoScrollSpeed: value(for: .scrollingAutoScrollSpeed),
            maximumLength: max(1_000, value(for: .scrollingMaximumLength))
        )
    }
}

extension Log {
    nonisolated static let scrolling = Logger(subsystem: subsystem, category: "scrolling")
}
