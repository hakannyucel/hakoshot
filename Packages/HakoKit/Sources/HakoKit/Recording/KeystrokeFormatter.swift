import Foundation

/// Which keystrokes the badge shows (plan §4.9). Same raw values as the
/// app's `KeystrokeFilter`.
public enum KeystrokeDisplayFilter: String, Sendable, Hashable, Codable, CaseIterable {
    /// Combos with ⌘, ⌃ or ⌥ (Shift alone doesn't count), plus special keys
    /// (Esc, Return, Tab, Delete, arrows, F-keys…) with or without modifiers.
    case shortcutsOnly
    /// Every key press (still no lone modifier presses).
    case allKeys
}

/// Modifier keys, using the device-independent bits shared by `CGEventFlags`
/// and `NSEvent.ModifierFlags` (so either raw value can be passed in).
public struct KeystrokeModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = KeystrokeModifiers(rawValue: 1 << 17)
    public static let control = KeystrokeModifiers(rawValue: 1 << 18)
    public static let option = KeystrokeModifiers(rawValue: 1 << 19)
    public static let command = KeystrokeModifiers(rawValue: 1 << 20)

    /// Keeps only ⇧⌃⌥⌘ from raw `CGEventFlags` / `NSEvent.ModifierFlags`
    /// bits; Caps Lock, Fn (set on arrows and F-keys), numeric pad and
    /// device-dependent bits are dropped.
    public init(eventFlags: UInt64) {
        self.init(rawValue: eventFlags & (Self.shift.rawValue | Self.control.rawValue | Self.option.rawValue | Self.command.rawValue))
    }

    /// ⌘, ⌃ or ⌥ present (what makes a combo a shortcut).
    public var hasShortcutModifier: Bool { !intersection([.command, .control, .option]).isEmpty }

    /// Apple menu order: ⌃⌥⇧⌘.
    public var glyphs: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A formatted key press, ready for the badge.
public struct FormattedKeystroke: Sendable, Hashable {
    /// e.g. "⇧⌘F", "↩", "⌃Space", "A".
    public var text: String
    public var modifiers: KeystrokeModifiers
    /// Esc, Return, Tab, Delete, arrows, F-keys, … (see `KeystrokeFormatter`).
    public var isSpecialKey: Bool

    /// Plan §4.9 filter.
    public func passes(_ filter: KeystrokeDisplayFilter) -> Bool {
        switch filter {
        case .allKeys: true
        case .shortcutsOnly: modifiers.hasShortcutModifier || isSpecialKey
        }
    }
}

/// Virtual key code (`kVK_*`) + modifiers → badge text (plan §4.9, R5.1/R5.2).
///
/// The key part comes from, in order: the special-key table (glyphs /
/// names), the event's characters ignoring modifiers (so non-US layouts show
/// their own letters), then a US-ANSI fallback table. Letters are uppercased.
/// Modifier keys on their own (`flagsChanged`) are never formatted.
public enum KeystrokeFormatter {
    /// Special keys → glyph. These pass the "Shortcuts only" filter alone.
    public static let specialKeys: [UInt16: String] = [
        0x24: "↩",      // Return
        0x4C: "⌤",      // Keypad Enter
        0x30: "⇥",      // Tab
        0x35: "⎋",      // Escape
        0x33: "⌫",      // Delete (backspace)
        0x75: "⌦",      // Forward Delete
        0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x73: "↖",      // Home
        0x77: "↘",      // End
        0x74: "⇞",      // Page Up
        0x79: "⇟",      // Page Down
        0x72: "Help",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        0x69: "F13", 0x6B: "F14", 0x71: "F15", 0x6A: "F16", 0x40: "F17", 0x4F: "F18",
        0x50: "F19", 0x5A: "F20",
    ]

    /// Named (not special) keys: shown only with a shortcut modifier under
    /// "Shortcuts only".
    public static let namedKeys: [UInt16: String] = [
        0x31: "Space",
    ]

    /// Modifier / lock keys: `flagsChanged` only, never shown alone.
    public static let modifierKeyCodes: Set<UInt16> = [0x36, 0x37, 0x38, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E, 0x3F]

    /// US-ANSI fallback when the event carries no characters.
    public static let ansiKeys: [UInt16: String] = [
        0x00: "A", 0x0B: "B", 0x08: "C", 0x02: "D", 0x0E: "E", 0x03: "F", 0x05: "G", 0x04: "H",
        0x22: "I", 0x26: "J", 0x28: "K", 0x25: "L", 0x2E: "M", 0x2D: "N", 0x1F: "O", 0x23: "P",
        0x0C: "Q", 0x0F: "R", 0x01: "S", 0x11: "T", 0x20: "U", 0x09: "V", 0x0D: "W", 0x07: "X",
        0x10: "Y", 0x06: "Z",
        0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7",
        0x1C: "8", 0x19: "9",
        0x1B: "-", 0x18: "=", 0x21: "[", 0x1E: "]", 0x2A: "\\", 0x29: ";", 0x27: "'", 0x2B: ",",
        0x2F: ".", 0x2C: "/", 0x32: "`",
    ]

    public static func isSpecialKey(_ keyCode: UInt16) -> Bool { specialKeys[keyCode] != nil }

    /// The key part alone ("F", "↩", "Space"); `nil` for modifier keys and
    /// unknown codes without characters.
    public static func keyName(keyCode: UInt16, characters: String? = nil) -> String? {
        if modifierKeyCodes.contains(keyCode) { return nil }
        if let special = specialKeys[keyCode] { return special }
        if let named = namedKeys[keyCode] { return named }
        if let characters {
            let visible = characters.filter { !$0.isWhitespace && !($0.unicodeScalars.first.map { CharacterSet.controlCharacters.contains($0) } ?? true) }
            if !visible.isEmpty { return visible.uppercased() }
        }
        return ansiKeys[keyCode]
    }

    /// Full formatted key press; `nil` when there's nothing to show.
    /// `modifierFlags` is raw `CGEventFlags` / `NSEvent.ModifierFlags` bits.
    public static func format(keyCode: UInt16, modifierFlags: UInt64, characters: String? = nil) -> FormattedKeystroke? {
        guard let key = keyName(keyCode: keyCode, characters: characters) else { return nil }
        let modifiers = KeystrokeModifiers(eventFlags: modifierFlags)
        return FormattedKeystroke(text: modifiers.glyphs + key, modifiers: modifiers, isSpecialKey: isSpecialKey(keyCode))
    }

    /// `format` + the filter: the badge text, or `nil` when the key press
    /// shouldn't be shown.
    public static func displayText(keyCode: UInt16, modifierFlags: UInt64, characters: String? = nil,
                                   filter: KeystrokeDisplayFilter) -> String? {
        guard let formatted = format(keyCode: keyCode, modifierFlags: modifierFlags, characters: characters),
              formatted.passes(filter) else { return nil }
        return formatted.text
    }

    /// Recorded key event → badge text (`flagsChanged` → `nil`).
    public static func displayText(for event: RecordingKeyEvent, filter: KeystrokeDisplayFilter) -> String? {
        guard event.kind == .keyDown else { return nil }
        return displayText(keyCode: event.keyCode, modifierFlags: event.modifierFlags, characters: event.characters, filter: filter)
    }

    /// Badge label with the repeat count: "⌘Z", "⌘Z ×3".
    public static func label(text: String, count: Int) -> String {
        count > 1 ? "\(text) ×\(count)" : text
    }
}

// MARK: - Repeat merging

/// One badge "run": the same text pressed `count` times in a row while the
/// badge was still on screen (plan §4.9: "⌘Z ×3").
public struct KeystrokeBadgeEntry: Sendable, Hashable {
    public var text: String
    /// Every press of the run, ascending (never empty).
    public var pressTimes: [Double]
    /// Where the fade-in curve starts. Equals `firstTime` when the badge
    /// appeared from nothing; earlier when it replaced a still-visible badge,
    /// so the badge stays at the alpha it already had instead of blinking.
    public var fadeInStart: Double

    public var count: Int { pressTimes.count }
    /// First press of the run (seconds, any clock).
    public var firstTime: Double { pressTimes.first ?? fadeInStart }
    /// Latest press; the badge holds from here.
    public var lastTime: Double { pressTimes.last ?? fadeInStart }
    /// "⌘Z" or "⌘Z ×3".
    public var label: String { KeystrokeFormatter.label(text: text, count: count) }

    public init(text: String, pressTimes: [Double], fadeInStart: Double? = nil) {
        self.text = text
        self.pressTimes = pressTimes.isEmpty ? [fadeInStart ?? 0] : pressTimes
        self.fadeInStart = fadeInStart ?? self.pressTimes[0]
    }

    public init(text: String, firstTime: Double, fadeInStart: Double? = nil) {
        self.init(text: text, pressTimes: [firstTime], fadeInStart: fadeInStart)
    }

    /// The run as it was at time `t` (presses after `t` dropped); `nil`
    /// before the first press.
    public func asOf(_ t: Double) -> KeystrokeBadgeEntry? {
        let presses = pressTimes.filter { $0 <= t }
        guard !presses.isEmpty else { return nil }
        return KeystrokeBadgeEntry(text: text, pressTimes: presses, fadeInStart: fadeInStart)
    }
}

/// Folds key presses (already formatted and filtered) into badge entries.
/// Used live (`KeystrokeBadgeLayer`) and for Studio renders
/// (`KeystrokeBadgeTimeline`), so both merge repeats the same way.
public struct KeystrokeRepeatMerger: Sendable, Hashable {
    public var timing: KeystrokeBadgeTiming
    public private(set) var entries: [KeystrokeBadgeEntry] = []

    public init(timing: KeystrokeBadgeTiming = .standard) {
        self.timing = timing
    }

    /// The current (last) entry.
    public var current: KeystrokeBadgeEntry? { entries.last }

    /// Adds a press at `time` (non-decreasing). Same text while the badge is
    /// still visible → the count goes up; otherwise a new entry starts.
    /// Returns the entry now on screen.
    @discardableResult
    public mutating func add(_ text: String, at time: Double) -> KeystrokeBadgeEntry {
        if var last = entries.last, timing.alpha(for: last, at: time) > 0 {
            if last.text == text {
                last.pressTimes.append(time)
                entries[entries.count - 1] = last
                return last
            }
            // Replace a visible badge without re-fading from zero.
            let visible = timing.alpha(for: last, at: time)
            let entry = KeystrokeBadgeEntry(text: text, firstTime: time, fadeInStart: time - timing.fadeIn * visible)
            entries.append(entry)
            return entry
        }
        let entry = KeystrokeBadgeEntry(text: text, firstTime: time)
        entries.append(entry)
        return entry
    }

    /// Drops every entry but the current one (live use keeps no history).
    public mutating func trimHistory() {
        if entries.count > 1 { entries.removeFirst(entries.count - 1) }
    }

    /// Forgets everything (the badge was cleared).
    public mutating func reset() {
        entries.removeAll()
    }

    /// Merges a whole list of `(time, text)` presses (sorted by time).
    public static func merge(_ presses: [(time: Double, text: String)], timing: KeystrokeBadgeTiming = .standard) -> [KeystrokeBadgeEntry] {
        var merger = KeystrokeRepeatMerger(timing: timing)
        for press in presses { merger.add(press.text, at: press.time) }
        return merger.entries
    }

    /// Recorded key events → badge entries through the formatter + filter.
    /// Auto-repeat key downs are skipped unless `includeAutoRepeat`.
    public static func merge(events: [RecordingKeyEvent], filter: KeystrokeDisplayFilter,
                             includeAutoRepeat: Bool = false,
                             timing: KeystrokeBadgeTiming = .standard) -> [KeystrokeBadgeEntry] {
        let presses: [(time: Double, text: String)] = events
            .filter { includeAutoRepeat || !$0.isRepeat }
            .sorted { $0.time < $1.time }
            .compactMap { event in
                KeystrokeFormatter.displayText(for: event, filter: filter).map { (event.time, $0) }
            }
        return merge(presses, timing: timing)
    }
}
