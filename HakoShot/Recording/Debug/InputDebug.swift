#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import HakoKit
import os

/// DEBUG-only input recording hooks (plan §7 R5.1):
///
/// - `hakoshot://debug-inject-input?kind=click|key&x=&y=&button=left|right|other&keys=cmd+shift+f`
///   injects a synthetic event straight into the running session's
///   `EventRecorder` (not into the system): a click is a down + up at the
///   Quartz global point (x, y) (default: the current mouse location), a key
///   is one key down (with `repeat=1` an auto-repeat). Live callbacks fire as
///   for real input, so the overlay ring / badge shows. Keys go through the
///   tap's secure-input check when a tap exists. Needs no permission.
/// - `hakoshot://debug-recording-events?out=<json>` writes
///   `EventRecorder.Snapshot` of the running recorder (media times with the
///   cached timeline), or of the last finished one after stop
///   (`{"active": false, ...}`).
enum InputDebug {
    nonisolated struct InjectParameters: Equatable, Sendable {
        enum Kind: String, Sendable { case click, key }

        var kind: Kind
        /// Quartz global point; `nil` = current mouse location.
        var point: CGPoint?
        var button: RecordingMouseButton
        /// e.g. "cmd+shift+f".
        var keys: String
        var isRepeat: Bool

        /// Keys: `kind` (required), `x y button` (click), `keys repeat` (key).
        init?(queryItems: [URLQueryItem]) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            guard let kind = values["kind"].flatMap({ Kind(rawValue: $0.lowercased()) }) else { return nil }
            self.kind = kind
            if let x = values["x"].flatMap(Double.init), let y = values["y"].flatMap(Double.init) {
                point = CGPoint(x: x, y: y)
            } else {
                point = nil
            }
            button = values["button"].flatMap { RecordingMouseButton(rawValue: $0.lowercased()) } ?? .left
            keys = values["keys"] ?? "cmd+shift+f"
            isRepeat = ["1", "true", "yes"].contains(values["repeat"]?.lowercased() ?? "")
            if kind == .key, InputDebug.parseKeys(keys) == nil { return nil }
        }
    }

    nonisolated struct ParsedKeys: Equatable, Sendable {
        var keyCode: UInt16
        var modifierFlags: UInt64
        var characters: String?
    }

    private static let log = Logger(subsystem: Log.subsystem, category: "input-debug")

    /// Injects into `EventRecorder.active`. `false` when no recorder runs.
    @discardableResult
    static func inject(_ parameters: InjectParameters, into recorder: EventRecorder? = EventRecorder.active) -> Bool {
        guard let recorder else {
            log.error("debug-inject-input: no recording session")
            return false
        }
        let now = HostTime.nowSeconds()
        switch parameters.kind {
        case .click:
            let point = parameters.point ?? CGEvent(source: nil)?.location ?? .zero
            recorder.ingestClick(MouseButtonEvent(hostTime: now, globalPoint: point, button: parameters.button, isDown: true, clickCount: 1))
            recorder.ingestClick(MouseButtonEvent(hostTime: now + 0.05, globalPoint: point, button: parameters.button, isDown: false, clickCount: 1))
            log.notice("injected \(parameters.button.rawValue, privacy: .public) click at \(point.x), \(point.y)")
        case .key:
            guard let parsed = parseKeys(parameters.keys) else { return false }
            recorder.injectKey(TappedKeyEvent(
                hostTime: now, kind: .keyDown, keyCode: parsed.keyCode, modifierFlags: parsed.modifierFlags,
                characters: parsed.characters, isRepeat: parameters.isRepeat
            ))
            log.notice("injected key \(parameters.keys, privacy: .public)")
        }
        return true
    }

    /// Writes the running (or last finished) recorder's snapshot as JSON.
    static func writeEvents(to url: URL) {
        var object: [String: Any] = ["active": EventRecorder.active != nil]
        if let snapshot = EventRecorder.active?.snapshot() ?? EventRecorder.lastFinished,
           let data = try? JSONEncoder().encode(snapshot),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object.merge(dictionary) { _, new in new }
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            log.notice("debug-recording-events written to \(url.path, privacy: .public)")
        } catch {
            log.error("debug-recording-events: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Key parsing

    /// "cmd+shift+f" → key code + `CGEventFlags` bits. Separators `+`, space
    /// or `,`; modifiers `cmd|command`, `shift`, `opt|option|alt`,
    /// `ctrl|control`; key: a letter/digit/punctuation (US ANSI) or a name
    /// (`esc return enter tab delete forwarddelete space left right up down
    /// home end pageup pagedown f1…f20`). `nil` when the key is unknown.
    nonisolated static func parseKeys(_ text: String) -> ParsedKeys? {
        let parts = text.lowercased()
            .split(whereSeparator: { $0 == "+" || $0 == " " || $0 == "," })
            .map(String.init)
        guard let keyPart = parts.last else { return nil }
        var flags: UInt64 = 0
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": flags |= KeystrokeModifiers.command.rawValue
            case "shift": flags |= KeystrokeModifiers.shift.rawValue
            case "opt", "option", "alt": flags |= KeystrokeModifiers.option.rawValue
            case "ctrl", "control": flags |= KeystrokeModifiers.control.rawValue
            default: return nil
            }
        }
        if let code = namedKeys[keyPart] { return ParsedKeys(keyCode: code, modifierFlags: flags, characters: nil) }
        if let entry = KeystrokeFormatter.ansiKeys.first(where: { $0.value.lowercased() == keyPart }) {
            return ParsedKeys(keyCode: entry.key, modifierFlags: flags, characters: keyPart)
        }
        return nil
    }

    nonisolated static let namedKeys: [String: UInt16] = {
        var keys: [String: UInt16] = [
            "esc": 0x35, "escape": 0x35, "return": 0x24, "enter": 0x4C, "tab": 0x30, "delete": 0x33,
            "backspace": 0x33, "forwarddelete": 0x75, "space": 0x31, "left": 0x7B, "right": 0x7C,
            "down": 0x7D, "up": 0x7E, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        ]
        for (code, name) in KeystrokeFormatter.specialKeys where name.hasPrefix("F") {
            keys[name.lowercased()] = code
        }
        return keys
    }()
}
#endif
