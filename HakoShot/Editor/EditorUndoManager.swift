import Foundation
import HakoKit

/// The editor window's `NSUndoManager`, backed by `EditorStore`'s own undo stack
/// (snapshots, interaction coalescing, 200 steps). The Edit menu's Undo/Redo
/// items and their titles ("Undo Move") read from here; ⌘Z / ⇧⌘Z are also
/// routed by `EditorWindow`. Typing inside a text box uses the text view's own
/// undo manager instead (`TextEditingController`).
final class EditorUndoManager: UndoManager {
    weak var model: EditorViewModel?

    override var canUndo: Bool {
        model?.store.canUndo ?? false
    }

    override var canRedo: Bool {
        model?.store.canRedo ?? false
    }

    override var undoActionName: String {
        model?.store.undoActionName ?? ""
    }

    override var redoActionName: String {
        model?.store.redoActionName ?? ""
    }

    override var undoMenuItemTitle: String {
        undoMenuTitle(forUndoActionName: undoActionName)
    }

    override var redoMenuItemTitle: String {
        redoMenuTitle(forUndoActionName: redoActionName)
    }

    override func undo() {
        model?.undo()
    }

    override func redo() {
        model?.redo()
    }
}
