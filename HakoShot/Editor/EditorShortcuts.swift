import AppKit
import HakoKit

/// A key press reduced to what the editor's shortcut table needs (pure, tested).
nonisolated struct EditorKeyInput: Equatable, Sendable {
    var characters: String
    var keyCode: UInt16
    var command = false
    var shift = false
    var option = false
    var control = false

    init(characters: String, keyCode: UInt16 = 0, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.characters = characters
        self.keyCode = keyCode
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    init(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        self.init(
            characters: (event.charactersIgnoringModifiers ?? "").lowercased(),
            keyCode: event.keyCode,
            command: flags.contains(.command),
            shift: flags.contains(.shift),
            option: flags.contains(.option),
            control: flags.contains(.control)
        )
    }

    enum KeyCode {
        static let delete: UInt16 = 51
        static let forwardDelete: UInt16 = 117
        static let escape: UInt16 = 53
        static let returnKey: UInt16 = 36
        static let enter: UInt16 = 76
        static let left: UInt16 = 123
        static let right: UInt16 = 124
        static let down: UInt16 = 125
        static let up: UInt16 = 126
    }
}

/// Everything a key can trigger in the editor.
nonisolated enum EditorCommand: Equatable, Sendable {
    // ⌘ shortcuts (plan §4.11)
    case undo, redo
    /// ⌘C: selected objects, or the rendered image when nothing is selected.
    case copy
    /// ⇧⌘C: always the rendered image.
    case copyImage
    case cut, paste
    case save, saveAs
    case duplicate
    case selectAll
    case zoomIn, zoomOut, zoomActualSize, zoomToFit
    case close
    /// ⌘I: "Add Image…" from a file (combine, WP5.4).
    case addImage
    /// ⇧⌘I: "Add New Screenshot" (combine a fresh capture).
    case addScreenshot

    // Plain keys (canvas, not while editing text)
    case selectTool(AnnotationTool)
    /// `1`–`6`: 0-based preset index.
    case sizePreset(Int)
    case increaseSize, decreaseSize
    case deleteSelection
    case nudge(dx: CGFloat, dy: CGFloat)
    case escape
    /// Return on a selected text annotation starts editing it.
    case editSelectedText
}

/// The editor's shortcut table (plan §4.11).
nonisolated enum EditorShortcuts {
    /// Tools whose single-letter shortcut is live: all of them. K toggles crop
    /// mode and B the Background panel (M5); neither changes the drawing tool.
    static let enabledTools: Set<AnnotationTool> = Set(AnnotationTool.allCases)

    /// ⌘-based shortcuts. `nil` = not ours (let the menu / text view have it).
    static func commandShortcut(for key: EditorKeyInput) -> EditorCommand? {
        guard key.command, !key.control else { return nil }
        switch (key.characters, key.shift, key.option) {
        case ("z", false, false): return .undo
        case ("z", true, false): return .redo
        case ("c", false, false): return .copy
        case ("c", true, false): return .copyImage
        case ("x", false, false): return .cut
        case ("v", false, false): return .paste
        case ("s", false, false): return .save
        case ("s", true, false): return .saveAs
        case ("d", false, false): return .duplicate
        case ("a", false, false): return .selectAll
        case ("=", _, false), ("+", _, false): return .zoomIn
        case ("-", false, false): return .zoomOut
        case ("0", false, false): return .zoomActualSize
        case ("9", false, false): return .zoomToFit
        case ("w", false, false): return .close
        case ("i", false, false): return .addImage
        case ("i", true, false): return .addScreenshot
        default: return nil
        }
    }

    /// Unmodified (or ⇧) keys on the canvas. Callers must not use this while a
    /// text box is being edited — letters are typing then.
    static func canvasKey(for key: EditorKeyInput) -> EditorCommand? {
        guard !key.command, !key.control else { return nil }
        let nudge = key.shift ? EditorMetrics.nudgeLarge : EditorMetrics.nudgeSmall
        switch key.keyCode {
        case EditorKeyInput.KeyCode.delete, EditorKeyInput.KeyCode.forwardDelete: return .deleteSelection
        case EditorKeyInput.KeyCode.escape: return .escape
        case EditorKeyInput.KeyCode.returnKey, EditorKeyInput.KeyCode.enter: return .editSelectedText
        case EditorKeyInput.KeyCode.left: return .nudge(dx: -nudge, dy: 0)
        case EditorKeyInput.KeyCode.right: return .nudge(dx: nudge, dy: 0)
        case EditorKeyInput.KeyCode.up: return .nudge(dx: 0, dy: -nudge)
        case EditorKeyInput.KeyCode.down: return .nudge(dx: 0, dy: nudge)
        default: break
        }
        guard !key.option, key.characters.count == 1, let character = key.characters.first else { return nil }
        if let digit = character.wholeNumberValue, (1...6).contains(digit), !key.shift {
            return .sizePreset(digit - 1)
        }
        switch character {
        case "]": return .increaseSize
        case "[": return .decreaseSize
        default: break
        }
        guard !key.shift, let tool = AnnotationTool.tool(forShortcut: character), enabledTools.contains(tool) else {
            return nil
        }
        return .selectTool(tool)
    }
}
