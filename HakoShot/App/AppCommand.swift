import CoreGraphics
import Foundation

/// Every user-triggerable action. Hotkeys, the menu bar and `hakoshot://` URLs
/// all produce an `AppCommand` and hand it to `AppCoordinator.perform(_:)`.
nonisolated enum AppCommand: Equatable, Sendable {
    case capture(CaptureMode, CaptureOptions = CaptureOptions())
    /// `rect` (Quartz global points, URL scheme only) skips the area overlay.
    case captureText(lineBreaks: Bool, rect: CGRect? = nil)
    case openHistory
    case restoreLastClosed
    /// `nil` means "ask the user to pick a file".
    case openEditor(URL?)
    case openFromClipboard
    case toggleDesktopIcons
    case closeAllPins
    case unlockAllPins
    case openSettings
    /// Opens Settings on one page (`SettingsPage` raw value, e.g. "shortcuts").
    case openSettingsPage(String)
    /// Shows the onboarding window from its first step.
    case openOnboarding
    #if DEBUG
    case showDesignSystemPreview
    case debugCaptureMainDisplay
    case debugQuickAccessSample
    case debugPinSample
    case debugHistorySample
    case debugCaptureFrontWindow
    /// Opens the annotated sample editor, saves it as a project at the URL, closes it.
    case debugEditorSaveProject(URL)
    /// Performs Edit (or Close) on the newest Quick Access card.
    case debugQuickAccessEdit(close: Bool = false)
    /// Closes every editor window without asking.
    case debugCloseEditors
    /// Adds the sample annotations to every open editor, then ⌘S.
    case debugAnnotateAndSaveEditors
    /// Removes one History entry (and its files).
    case debugRemoveHistoryEntry(UUID)
    /// Presses Done on the running scrolling capture.
    case debugFinishScrolling
    /// Routes a synthetic tall `.scrolling` result like a finished scrolling capture
    /// (checks Quick Access / history wiring when the display can't be captured).
    case debugScrollingSample(CaptureOptions)
    /// Sets one global shortcut (`nil` key code clears it); modifiers are `NSEvent.ModifierFlags` raw values.
    case debugSetShortcut(name: String, keyCode: Int?, modifiers: UInt)
    case debugResetShortcuts
    /// Opens Settings on `page` and writes the window's content as PNG (works with the display asleep).
    case debugSnapshotSettings(page: String, url: URL)
    #endif
}

nonisolated enum CaptureMode: Equatable, Sendable {
    case area
    case window
    case fullscreen(FullscreenTarget)
    case previousArea
    case scrolling
    case selfTimer
    case allInOne
    case text
}

nonisolated enum FullscreenTarget: Equatable, Sendable {
    /// Follow Settings > Screenshots > Fullscreen display.
    case preferred
    /// The display under the mouse cursor.
    case activeDisplay
    case allDisplays
}

/// Overrides that can accompany a capture (mainly from URL commands).
nonisolated struct CaptureOptions: Equatable, Sendable {
    /// Pre-selected rect in Quartz global points (top-left origin, see plan §3.2).
    var rect: CGRect?
    /// Overrides the after-capture settings for this one capture.
    var action: PostCaptureAction?
    /// Scrolling capture: start capturing without the "Start Capture" step;
    /// `nil` follows Settings > Screenshots > Scrolling (URL `start=`).
    var start: Bool?
    /// Scrolling capture: auto-scroll right away (URL `autoscroll=`).
    var autoScroll: Bool

    init(rect: CGRect? = nil, action: PostCaptureAction? = nil, start: Bool? = nil, autoScroll: Bool = false) {
        self.rect = rect
        self.action = action
        self.start = start
        self.autoScroll = autoScroll
    }
}

nonisolated enum PostCaptureAction: String, Equatable, Sendable, CaseIterable {
    case copy
    case save
    case annotate
    case pin
}

// MARK: - Logging

extension AppCommand: CustomStringConvertible {
    nonisolated var description: String {
        switch self {
        case let .capture(mode, options):
            var parts: [String] = []
            if let rect = options.rect {
                parts.append("rect=\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width))x\(Int(rect.height))")
            }
            if let action = options.action { parts.append("action=\(action.rawValue)") }
            if let start = options.start { parts.append("start=\(start)") }
            if options.autoScroll { parts.append("autoscroll") }
            let suffix = parts.isEmpty ? "" : ", " + parts.joined(separator: ", ")
            return "capture(\(mode)\(suffix))"
        case let .captureText(lineBreaks, rect):
            let suffix = rect.map { ", rect=\(Int($0.minX)),\(Int($0.minY)),\(Int($0.width))x\(Int($0.height))" } ?? ""
            return "captureText(lineBreaks: \(lineBreaks)\(suffix))"
        case .openHistory: return "openHistory"
        case .restoreLastClosed: return "restoreLastClosed"
        case let .openEditor(url): return "openEditor(\(url?.path ?? "choose file"))"
        case .openFromClipboard: return "openFromClipboard"
        case .toggleDesktopIcons: return "toggleDesktopIcons"
        case .closeAllPins: return "closeAllPins"
        case .unlockAllPins: return "unlockAllPins"
        case .openSettings: return "openSettings"
        case let .openSettingsPage(page): return "openSettings(\(page))"
        case .openOnboarding: return "openOnboarding"
        #if DEBUG
        case .showDesignSystemPreview: return "showDesignSystemPreview"
        case .debugCaptureMainDisplay: return "debugCaptureMainDisplay"
        case .debugQuickAccessSample: return "debugQuickAccessSample"
        case .debugPinSample: return "debugPinSample"
        case .debugHistorySample: return "debugHistorySample"
        case .debugCaptureFrontWindow: return "debugCaptureFrontWindow"
        case let .debugEditorSaveProject(url): return "debugEditorSaveProject(\(url.path))"
        case let .debugQuickAccessEdit(close): return close ? "debugQuickAccessClose" : "debugQuickAccessEdit"
        case .debugCloseEditors: return "debugCloseEditors"
        case .debugAnnotateAndSaveEditors: return "debugAnnotateAndSaveEditors"
        case let .debugRemoveHistoryEntry(id): return "debugRemoveHistoryEntry(\(id.uuidString))"
        case .debugFinishScrolling: return "debugFinishScrolling"
        case .debugScrollingSample: return "debugScrollingSample"
        case let .debugSetShortcut(name, keyCode, modifiers):
            return "debugSetShortcut(\(name), keyCode: \(keyCode.map(String.init) ?? "none"), modifiers: \(modifiers))"
        case .debugResetShortcuts: return "debugResetShortcuts"
        case let .debugSnapshotSettings(page, url): return "debugSnapshotSettings(\(page), \(url.path))"
        #endif
        }
    }
}
