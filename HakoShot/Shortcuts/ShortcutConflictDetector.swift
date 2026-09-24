import AppKit
import Carbon.HIToolbox
import KeyboardShortcuts
import os

/// A key + modifier combination, comparable across HakoShot's shortcuts and
/// macOS's symbolic hotkeys. Only ⌘ ⇧ ⌥ ⌃ count as modifiers.
nonisolated struct ShortcutCombo: Hashable, Sendable {
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Virtual (Carbon) key code, e.g. `kVK_ANSI_4` = 21.
    let keyCode: Int
    /// `NSEvent.ModifierFlags` raw value, masked to `relevantModifiers`.
    let modifierFlags: UInt

    init(keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        modifierFlags = modifiers.intersection(Self.relevantModifiers).rawValue
    }

    init(_ shortcut: KeyboardShortcuts.Shortcut) {
        self.init(keyCode: shortcut.carbonKeyCode, modifiers: shortcut.modifiers)
    }

    var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierFlags) }

    var carbonModifiers: Int {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        return result
    }

    /// "⌃⌥⇧⌘" order, as macOS menus show it.
    var modifierSymbols: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text
    }
}

/// One of macOS's own screenshot shortcuts (System Settings › Keyboard ›
/// Keyboard Shortcuts › Screenshots).
nonisolated struct SystemScreenshotShortcut: Equatable, Sendable {
    /// Key in `AppleSymbolicHotKeys`.
    let id: Int
    let title: String
    let combo: ShortcutCombo
    let isEnabled: Bool
}

/// A macOS screenshot shortcut that is on and uses a combo HakoShot is bound to.
nonisolated struct SystemShortcutConflict: Equatable, Sendable {
    let system: SystemScreenshotShortcut
    /// HakoShot shortcut names (raw values) using the same combo.
    let names: [String]
}

/// Finds shortcut clashes (plan §2.4, WP7.1):
/// - two HakoShot commands on the same combo (both would fire);
/// - macOS screenshot shortcuts (symbolic hotkeys 28/29/30/31/184) that are
///   still on for a combo HakoShot uses — macOS handles those first, so the
///   HakoShot hotkey never fires.
///
/// Pure logic over plain dictionaries so tests can feed fake data; the
/// `read…` helpers supply the live values. Never writes the system plist.
nonisolated enum ShortcutConflictDetector {
    static let symbolicHotKeysDomain = "com.apple.symbolichotkeys"
    static let symbolicHotKeysKey = "AppleSymbolicHotKeys"

    /// macOS defaults, used when the plist has no entry (or no `value`) for an id.
    static let screenshotDefaults: [(id: Int, title: String, combo: ShortcutCombo)] = [
        (28, "Save picture of screen as a file", ShortcutCombo(keyCode: kVK_ANSI_3, modifiers: [.command, .shift])),
        (29, "Copy picture of screen to the clipboard", ShortcutCombo(keyCode: kVK_ANSI_3, modifiers: [.command, .shift, .control])),
        (30, "Save picture of selected area as a file", ShortcutCombo(keyCode: kVK_ANSI_4, modifiers: [.command, .shift])),
        (31, "Copy picture of selected area to the clipboard", ShortcutCombo(keyCode: kVK_ANSI_4, modifiers: [.command, .shift, .control])),
        (184, "Screenshot and recording options", ShortcutCombo(keyCode: kVK_ANSI_5, modifiers: [.command, .shift])),
    ]

    // MARK: HakoShot duplicates

    /// Other names in `assignments` bound to `combo`, sorted.
    static func duplicates(of combo: ShortcutCombo, excluding name: String, in assignments: [String: ShortcutCombo]) -> [String] {
        assignments.filter { $0.key != name && $0.value == combo }.map(\.key).sorted()
    }

    /// Every combo used by more than one name, with those names (sorted).
    static func duplicateGroups(in assignments: [String: ShortcutCombo]) -> [ShortcutCombo: [String]] {
        Dictionary(grouping: assignments, by: \.value)
            .filter { $0.value.count > 1 }
            .mapValues { $0.map(\.key).sorted() }
    }

    // MARK: macOS screenshot shortcuts

    /// The five screenshot hotkeys as the given `AppleSymbolicHotKeys`
    /// dictionary describes them. A missing dictionary or entry means the
    /// macOS default (on, default combo).
    static func systemScreenshotShortcuts(symbolicHotKeys: [String: Any]?) -> [SystemScreenshotShortcut] {
        screenshotDefaults.map { entry in
            guard let item = symbolicHotKeys?[String(entry.id)] as? [String: Any] else {
                return SystemScreenshotShortcut(id: entry.id, title: entry.title, combo: entry.combo, isEnabled: true)
            }
            let enabled = boolValue(item["enabled"]) ?? true
            return SystemScreenshotShortcut(
                id: entry.id,
                title: entry.title,
                combo: combo(fromValue: item["value"]) ?? entry.combo,
                isEnabled: enabled
            )
        }
    }

    /// Enabled macOS screenshot shortcuts whose combo a HakoShot shortcut uses.
    static func systemConflicts(
        assignments: [String: ShortcutCombo],
        symbolicHotKeys: [String: Any]?
    ) -> [SystemShortcutConflict] {
        systemScreenshotShortcuts(symbolicHotKeys: symbolicHotKeys).compactMap { system in
            guard system.isEnabled else { return nil }
            let names = assignments.filter { $0.value == system.combo }.map(\.key).sorted()
            return names.isEmpty ? nil : SystemShortcutConflict(system: system, names: names)
        }
    }

    /// `{ parameters = (ascii, keyCode, modifierFlags); type = standard; }`.
    static func combo(fromValue value: Any?) -> ShortcutCombo? {
        guard let value = value as? [String: Any],
              let parameters = value["parameters"] as? [Any], parameters.count >= 3,
              let keyCode = intValue(parameters[1]), let flags = intValue(parameters[2]),
              keyCode >= 0, keyCode != 0xFFFF, flags >= 0
        else { return nil }
        return ShortcutCombo(keyCode: keyCode, modifiers: NSEvent.ModifierFlags(rawValue: UInt(flags)))
    }

    // MARK: Live values

    /// The current `AppleSymbolicHotKeys` dictionary, freshly read (the app
    /// isn't sandboxed, plan §2.3). `nil` when the user never changed any.
    static func readSymbolicHotKeys() -> [String: Any]? {
        CFPreferencesAppSynchronize(symbolicHotKeysDomain as CFString)
        let value = CFPreferencesCopyAppValue(symbolicHotKeysKey as CFString, symbolicHotKeysDomain as CFString)
        return value as? [String: Any]
    }

    /// System Settings › Keyboard (the Keyboard Shortcuts… button is there).
    static let keyboardSettingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")

    // MARK: Helpers

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let int as Int: int
        case let string as String: Int(string)
        default: nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let number as NSNumber: number.boolValue
        case let bool as Bool: bool
        case let string as String: ["1", "true", "yes"].contains(string.lowercased())
        default: nil
        }
    }
}

/// Which combos a recorder accepts (plan §1.5):
/// at least one of ⌘ ⌃ ⌥, or a bare function key (F1–F20).
nonisolated enum ShortcutValidation {
    static let functionKeyCodes: Set<Int> = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys a recorder never stores on their own.
    static let modifierKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]

    static func isAcceptable(_ combo: ShortcutCombo) -> Bool {
        guard !modifierKeyCodes.contains(combo.keyCode) else { return false }
        if functionKeyCodes.contains(combo.keyCode) { return true }
        return !combo.modifiers.isDisjoint(with: [.command, .control, .option])
    }
}
