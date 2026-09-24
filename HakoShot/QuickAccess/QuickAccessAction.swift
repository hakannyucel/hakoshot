import AppKit
import Foundation

/// Everything a user can do to one Quick Access card (hover controls, context menu,
/// keyboard). The controller performs them; the view only emits them.
nonisolated enum QuickAccessAction: Equatable, Sendable {
    /// `keepOpen`: ⌥-click / ⌥⌘C copies without closing (plan §4.12).
    case copy(keepOpen: Bool)
    case save
    case saveAs
    case edit
    case pin
    case showInFinder
    case close
    case closeAll
    /// Return: save, then close.
    case saveAndClose
}

/// Keyboard shortcuts while the card panel is key (plan §4.12; report §1):
/// ⌘C copy (⌥⌘C keeps the card), ⌘S save, ⌘⇧S save as, ⌘E edit, ⌘P pin, ⌘W / Esc close,
/// ⌘⌥W close all, Return save and close.
nonisolated enum QuickAccessKeyMap {
    static let escapeKeyCode: UInt16 = 53
    static let returnKeyCode: UInt16 = 36
    static let keypadEnterKeyCode: UInt16 = 76

    static func action(
        keyCode: UInt16,
        characters: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> QuickAccessAction? {
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        if flags.isEmpty {
            switch keyCode {
            case escapeKeyCode: return .close
            case returnKeyCode, keypadEnterKeyCode: return .saveAndClose
            default: return nil
            }
        }
        guard flags.contains(.command), !flags.contains(.control) else { return nil }
        let key = characters?.lowercased()
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        switch key {
        case "c": return shift ? nil : .copy(keepOpen: option)
        case "s": return option ? nil : (shift ? .saveAs : .save)
        case "e": return (option || shift) ? nil : .edit
        case "p": return (option || shift) ? nil : .pin
        case "w": return shift ? nil : (option ? .closeAll : .close)
        default: return nil
        }
    }
}
