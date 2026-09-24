import AppKit
import KeyboardShortcuts
import os

/// Global shortcut names and their defaults (plan §5.1; recording:
/// kayit-teknik-plan §4.21). KeyboardShortcuts
/// stores the user's value in `UserDefaults` (`KeyboardShortcuts_<name>`);
/// `initial:` is written only when nothing is stored yet.
///
/// To add a shortcut: declare a `Name` here and add it to
/// `ShortcutBinding.all` with the `AppCommand` it sends.
extension KeyboardShortcuts.Name {
    static let allInOne = Self("allInOne", initial: .init(.one, modifiers: [.command, .shift]))
    static let captureText = Self("captureText", initial: .init(.two, modifiers: [.command, .shift]))
    static let captureFullscreen = Self("captureFullscreen", initial: .init(.three, modifiers: [.command, .shift]))
    static let captureArea = Self("captureArea", initial: .init(.four, modifiers: [.command, .shift]))
    static let captureWindow = Self("captureWindow", initial: .init(.five, modifiers: [.command, .shift]))
    static let capturePreviousArea = Self("capturePreviousArea", initial: .init(.six, modifiers: [.command, .shift]))
    static let scrollingCapture = Self("scrollingCapture", initial: .init(.seven, modifiers: [.command, .shift]))
    static let selfTimer = Self("selfTimer", initial: .init(.eight, modifiers: [.command, .shift]))
    /// Record Screen; stops while recording (kayit-teknik-plan §4.21, user decision §9.2-1).
    static let recordScreen = Self("recordScreen", initial: .init(.nine, modifiers: [.command, .shift]))
    // Recording commands without a default (plan §4.21).
    static let recordGIF = Self("recordGIF")
    static let recordStudio = Self("recordStudio")
    static let togglePauseRecording = Self("togglePauseRecording")
    static let restartRecording = Self("restartRecording")
    static let discardRecording = Self("discardRecording")
    static let openVideoEditor = Self("openVideoEditor")
    // Unassigned by default (plan §5.1); the user sets them in Settings > Shortcuts (M7).
    static let captureTextWithoutLineBreaks = Self("captureTextWithoutLineBreaks")
    static let openHistory = Self("openHistory")
    static let toggleDesktopIcons = Self("toggleDesktopIcons")
    static let closeAllPins = Self("closeAllPins")
    static let openFromClipboard = Self("openFromClipboard")
}

/// Shortcuts page sections.
enum ShortcutGroup: String, CaseIterable, Identifiable {
    case capture = "Capture"
    case recording = "Recording"
    case text = "Text"
    case tools = "Tools"

    var id: String { rawValue }
}

/// One global shortcut, the command it sends and how Settings lists it.
struct ShortcutBinding: Identifiable {
    var name: KeyboardShortcuts.Name
    var command: AppCommand
    var title: String
    var group: ShortcutGroup

    var id: String { name.rawValue }

    /// Settings > Shortcuts order (menu order within each group).
    static let all: [ShortcutBinding] = [
        ShortcutBinding(name: .captureArea, command: .capture(.area), title: "Capture Area", group: .capture),
        ShortcutBinding(name: .capturePreviousArea, command: .capture(.previousArea), title: "Capture Previous Area", group: .capture),
        ShortcutBinding(name: .captureFullscreen, command: .capture(.fullscreen(.preferred)), title: "Capture Fullscreen", group: .capture),
        ShortcutBinding(name: .captureWindow, command: .capture(.window), title: "Capture Window", group: .capture),
        ShortcutBinding(name: .scrollingCapture, command: .capture(.scrolling), title: "Scrolling Capture", group: .capture),
        ShortcutBinding(name: .selfTimer, command: .capture(.selfTimer), title: "Self-Timer", group: .capture),
        ShortcutBinding(name: .allInOne, command: .capture(.allInOne), title: "All-In-One", group: .capture),
        ShortcutBinding(name: .recordScreen, command: .record(.area), title: "Record Screen", group: .recording),
        ShortcutBinding(
            name: .recordGIF, command: .record(.area, RecordingCommandOptions(format: .gif)),
            title: "Record GIF", group: .recording
        ),
        ShortcutBinding(
            name: .recordStudio, command: .record(.area, RecordingCommandOptions(studio: true)),
            title: "Record in Studio Mode", group: .recording
        ),
        ShortcutBinding(
            name: .togglePauseRecording, command: .togglePauseRecording,
            title: "Pause / Resume Recording", group: .recording
        ),
        ShortcutBinding(name: .restartRecording, command: .restartRecording, title: "Restart Recording", group: .recording),
        ShortcutBinding(
            name: .discardRecording, command: .discardRecording(confirm: true),
            title: "Discard Recording", group: .recording
        ),
        ShortcutBinding(name: .openVideoEditor, command: .openVideoEditor(nil), title: "Open Video Editor…", group: .recording),
        ShortcutBinding(name: .captureText, command: .captureText(lineBreaks: true), title: "Capture Text", group: .text),
        ShortcutBinding(
            name: .captureTextWithoutLineBreaks, command: .captureText(lineBreaks: false),
            title: "Capture Text Without Line Breaks", group: .text
        ),
        ShortcutBinding(name: .openHistory, command: .openHistory, title: "Open Capture History", group: .tools),
        ShortcutBinding(name: .toggleDesktopIcons, command: .toggleDesktopIcons, title: "Toggle Desktop Icons", group: .tools),
        ShortcutBinding(name: .closeAllPins, command: .closeAllPins, title: "Close All Pins", group: .tools),
        ShortcutBinding(name: .openFromClipboard, command: .openFromClipboard, title: "Open from Clipboard", group: .tools),
    ]

    /// The shortcut name bound to `command`, for showing it in the menu.
    static func name(for command: AppCommand) -> KeyboardShortcuts.Name? {
        all.first { $0.command == command }?.name
    }

    static func binding(named rawValue: String) -> ShortcutBinding? {
        all.first { $0.name.rawValue.caseInsensitiveCompare(rawValue) == .orderedSame }
    }

    /// Current assignments by raw name (unassigned names left out).
    static func currentAssignments() -> [String: ShortcutCombo] {
        var result: [String: ShortcutCombo] = [:]
        for binding in all {
            if let shortcut = KeyboardShortcuts.getShortcut(for: binding.name) {
                result[binding.name.rawValue] = ShortcutCombo(shortcut)
            }
        }
        return result
    }

    /// Restores the plan §5.1 defaults for every shortcut.
    static func resetAllToDefaults() {
        KeyboardShortcuts.reset(all.map(\.name))
        Log.shortcuts.notice("shortcuts reset to defaults")
    }

    #if DEBUG
    /// DEBUG URL `debug-set-shortcut`: `keyCode == nil` clears the shortcut.
    static func debugSet(name rawValue: String, keyCode: Int?, modifiers: UInt) {
        guard let binding = binding(named: rawValue) else {
            Log.shortcuts.error("debug: unknown shortcut name \(rawValue, privacy: .public)")
            return
        }
        let shortcut = keyCode.map {
            KeyboardShortcuts.Shortcut(
                carbonKeyCode: $0,
                carbonModifiers: ShortcutCombo(keyCode: $0, modifiers: NSEvent.ModifierFlags(rawValue: modifiers)).carbonModifiers
            )
        }
        KeyboardShortcuts.setShortcut(shortcut, for: binding.name)
        let text = shortcut.map { "\($0)" } ?? "none"
        Log.shortcuts.notice("debug: \(binding.name.rawValue, privacy: .public) = \(text, privacy: .public)")
    }
    #endif
}
