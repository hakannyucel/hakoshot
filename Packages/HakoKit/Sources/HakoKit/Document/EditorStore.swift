import CoreGraphics
import Foundation
import Observation

// MARK: - State

/// Everything the editor reducer operates on. Only `document` is undoable;
/// selection is restored alongside it on undo/redo, tool state never is.
public struct EditorState: Sendable, Hashable {
    public var document: ProjectDocument
    public var selection: Set<Annotation.ID>
    public var tool: AnnotationTool
    public var toolSettings: ToolSettings

    public init(
        document: ProjectDocument,
        selection: Set<Annotation.ID> = [],
        tool: AnnotationTool = .arrow,
        toolSettings: ToolSettings = ToolSettings()
    ) {
        self.document = document
        self.selection = selection
        self.tool = tool
        self.toolSettings = toolSettings
    }

    /// Selected annotations in z-order.
    public var selectedAnnotations: [Annotation] {
        document.annotations.filter { selection.contains($0.id) }
    }

    /// Number the next counter should get.
    public var nextCounterNumber: Int {
        document.nextCounterNumber(start: toolSettings.counterStartNumber)
    }
}

// MARK: - Actions

public enum ReorderOperation: String, Sendable, Hashable, CaseIterable {
    case bringToFront, bringForward, sendBackward, sendToBack
}

/// A partial edit applied to every targeted annotation. `nil` fields are left
/// alone; fields that don't apply to a kind are ignored for it.
public struct AnnotationPatch: Sendable, Hashable {
    public var color: RGBAColor?
    /// Also resizes counters (`diameter = max(5·w, 24·scale)`).
    public var strokeWidth: Double?
    public var opacity: Double?
    public var shadow: Bool?
    /// `.some(nil)` removes the fill.
    public var fill: RGBAColor??
    public var cornerRadius: Double?
    public var arrowStyle: ArrowStyle?
    public var text: String?
    public var textStyle: TextStyle?
    public var fontSize: Double?
    public var textAlignment: TextAlignmentMode?
    public var counterStyle: CounterStyle?
    public var counterNumber: Int?
    /// Changing the method resets `strength` to the method's default unless
    /// `redactionStrength` is also set.
    public var redactionMethod: RedactionMethod?
    public var redactionStrength: Double?
    public var dimOpacity: Double?

    public init(
        color: RGBAColor? = nil,
        strokeWidth: Double? = nil,
        opacity: Double? = nil,
        shadow: Bool? = nil,
        fill: RGBAColor?? = nil,
        cornerRadius: Double? = nil,
        arrowStyle: ArrowStyle? = nil,
        text: String? = nil,
        textStyle: TextStyle? = nil,
        fontSize: Double? = nil,
        textAlignment: TextAlignmentMode? = nil,
        counterStyle: CounterStyle? = nil,
        counterNumber: Int? = nil,
        redactionMethod: RedactionMethod? = nil,
        redactionStrength: Double? = nil,
        dimOpacity: Double? = nil
    ) {
        self.color = color
        self.strokeWidth = strokeWidth
        self.opacity = opacity
        self.shadow = shadow
        self.fill = fill
        self.cornerRadius = cornerRadius
        self.arrowStyle = arrowStyle
        self.text = text
        self.textStyle = textStyle
        self.fontSize = fontSize
        self.textAlignment = textAlignment
        self.counterStyle = counterStyle
        self.counterNumber = counterNumber
        self.redactionMethod = redactionMethod
        self.redactionStrength = redactionStrength
        self.dimOpacity = dimOpacity
    }
}

/// Every editor mutation. Document-changing actions become undo steps
/// (coalesced while an interaction is open, see `EditorStore`).
public enum EditorAction: Sendable, Hashable {
    // Annotations
    /// Appends on top of the z-order; selects it when `select`.
    case add(Annotation, select: Bool = true)
    /// Replaces the annotation with the same ID (creation drags, text edits).
    case update(Annotation)
    case delete(Set<Annotation.ID>)
    case deleteSelection
    case move(Set<Annotation.ID>, by: CGVector)
    case resize(Annotation.ID, handle: AnnotationHandle, to: CGPoint, keepAspect: Bool = false)
    case restyle(Set<Annotation.ID>, AnnotationPatch)
    case reorder(Set<Annotation.ID>, ReorderOperation)
    /// Copies on top of the z-order, offset by `offset`; selects the copies.
    /// Duplicated counters get the next free numbers.
    case duplicate(Set<Annotation.ID>, offset: CGVector)
    /// Renumbers all counters `start, start+1, …`, keeping their current
    /// numeric order (ties broken by z-order). Also sets `counterStartNumber`.
    case renumberCounters(startingAt: Int)

    // Selection (not undoable on its own)
    case select(Set<Annotation.ID>)
    case addToSelection(Set<Annotation.ID>)
    case toggleSelection(Annotation.ID)
    case selectAll
    case clearSelection

    // Tools (not undoable)
    case setTool(AnnotationTool)
    case setToolSettings(ToolSettings)

    // Canvas (M5)
    /// Crop in canvas pixels (clamped to the canvas); `nil` reverts.
    case setCrop(CGRect?)
    case setBackground(BackgroundStyle?)
    case setTransform(CanvasTransform)

    // Canvas operations (WP5.4, `CanvasOperations`)
    /// Adds an `.image` annotation where it is and grows the canvas to fit it
    /// (drops, pastes). Selects it when `select`.
    case insertImage(Annotation, select: Bool = true)
    /// Combine: places the `.image` annotation (its frame size is kept) next
    /// to the visible content on `edge` and grows the canvas. Selects it.
    case combineImage(Annotation, edge: CombineEdge = .right, spacing: Double = 0)
    /// Canvas size in pixels; the content is placed by `anchor`.
    case resizeCanvas(width: Int, height: Int, anchor: BackgroundAlignment = .center)
    /// Scales everything so the visible area becomes `width × height` pixels.
    case resizeImage(width: Int, height: Int)

    /// Name for the Undo/Redo menu items ("Undo Move").
    public var undoName: String {
        switch self {
        case .add(let a, _): "Add \(a.kind.tag.displayName)"
        case .update: "Edit"
        case .delete, .deleteSelection: "Delete"
        case .move: "Move"
        case .resize: "Resize"
        case .restyle: "Change Style"
        case .reorder: "Arrange"
        case .duplicate: "Duplicate"
        case .renumberCounters: "Renumber Counters"
        case .select, .addToSelection, .toggleSelection, .selectAll, .clearSelection: "Select"
        case .setTool, .setToolSettings: "Tool"
        case .setCrop: "Crop"
        case .setBackground: "Background"
        case .setTransform: "Rotate"
        case .insertImage: "Add Image"
        case .combineImage: "Combine Images"
        case .resizeCanvas: "Canvas Size"
        case .resizeImage: "Resize Image"
        }
    }
}

extension Annotation.KindTag {
    public var displayName: String {
        switch self {
        case .rectangle: "Rectangle"
        case .filledRectangle: "Filled Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .text: "Text"
        case .pencil: "Drawing"
        case .highlighter: "Highlight"
        case .counter: "Counter"
        case .redaction: "Redaction"
        case .spotlight: "Spotlight"
        case .image: "Image"
        }
    }
}

// MARK: - Reducer

/// The pure reducer (plan §4.10). Tests drive it directly.
public enum EditorReducer {
    public static func reduce(_ state: EditorState, _ action: EditorAction) -> EditorState {
        var copy = state
        reduce(&copy, action)
        return copy
    }

    public static func reduce(_ state: inout EditorState, _ action: EditorAction) {
        let scale = state.document.canvas.scale
        switch action {
        case .add(let annotation, let select):
            guard state.document.index(of: annotation.id) == nil else { return }
            state.document.annotations.append(annotation)
            if select { state.selection = [annotation.id] }

        case .update(let annotation):
            guard let i = state.document.index(of: annotation.id) else { return }
            state.document.annotations[i] = annotation

        case .delete(let ids):
            state.document.annotations.removeAll { ids.contains($0.id) }
            state.selection.subtract(ids)

        case .deleteSelection:
            reduce(&state, .delete(state.selection))

        case .move(let ids, let delta):
            mutate(&state, ids) { $0.translated(by: delta) }

        case .resize(let id, let handle, let point, let keepAspect):
            mutate(&state, [id]) { $0.resized(handle: handle, to: point, keepAspect: keepAspect) }

        case .restyle(let ids, let patch):
            mutate(&state, ids) { $0.applying(patch, scale: scale) }

        case .reorder(let ids, let operation):
            state.document.annotations = reordered(state.document.annotations, ids: ids, operation: operation)

        case .duplicate(let ids, let offset):
            var next = state.nextCounterNumber
            var copies: [Annotation] = []
            for original in state.document.annotations where ids.contains(original.id) {
                var copy = original.translated(by: offset)
                copy.id = UUID()
                if case .counter(var shape) = copy.kind {
                    shape.number = next
                    next += 1
                    copy.kind = .counter(shape)
                }
                copies.append(copy)
            }
            guard !copies.isEmpty else { return }
            state.document.annotations.append(contentsOf: copies)
            state.selection = Set(copies.map(\.id))

        case .renumberCounters(let start):
            state.toolSettings.counterStartNumber = start
            let order = state.document.annotations.indices
                .compactMap { i in state.document.annotations[i].counter.map { (index: i, number: $0.number) } }
                .sorted { ($0.number, $0.index) < ($1.number, $1.index) }
            for (offset, entry) in order.enumerated() {
                if case .counter(var shape) = state.document.annotations[entry.index].kind {
                    shape.number = start + offset
                    state.document.annotations[entry.index].kind = .counter(shape)
                }
            }

        case .select(let ids):
            state.selection = existing(ids, in: state.document)
        case .addToSelection(let ids):
            state.selection.formUnion(existing(ids, in: state.document))
        case .toggleSelection(let id):
            if state.selection.contains(id) {
                state.selection.remove(id)
            } else if state.document.index(of: id) != nil {
                state.selection.insert(id)
            }
        case .selectAll:
            state.selection = Set(state.document.annotations.map(\.id))
        case .clearSelection:
            state.selection = []

        case .setTool(let tool):
            state.tool = tool
            if tool != .move { state.selection = [] }
        case .setToolSettings(let settings):
            state.toolSettings = settings

        case .setCrop(let rect):
            if let rect {
                let clamped = rect.standardized.intersection(state.document.canvas.rect)
                state.document.crop = clamped.isNull || clamped.isEmpty ? nil : clamped
            } else {
                state.document.crop = nil
            }
        case .setBackground(let background):
            state.document.background = background
        case .setTransform(let transform):
            state.document.transform = transform

        case .insertImage(let image, let select):
            guard state.document.index(of: image.id) == nil else { return }
            state.document = CanvasOperations.insertingImage(image, into: state.document)
            if select { state.selection = [image.id] }
        case .combineImage(var image, let edge, let spacing):
            guard state.document.index(of: image.id) == nil else { return }
            let frame = CanvasOperations.combineFrame(for: image.bounds.size, beside: state.document, edge: edge, spacing: spacing)
            let old = image.bounds
            image = image.translated(by: CGVector(dx: frame.minX - old.minX, dy: frame.minY - old.minY))
            state.document = CanvasOperations.insertingImage(image, into: state.document)
            state.selection = [image.id]
        case .resizeCanvas(let width, let height, let anchor):
            state.document = CanvasOperations.resizingCanvas(state.document, width: width, height: height, anchor: anchor)
        case .resizeImage(let width, let height):
            state.document = CanvasOperations.resizingImage(state.document, width: width, height: height)
        }
    }

    // MARK: Helpers

    private static func mutate(_ state: inout EditorState, _ ids: Set<Annotation.ID>, _ body: (Annotation) -> Annotation) {
        for i in state.document.annotations.indices where ids.contains(state.document.annotations[i].id) {
            state.document.annotations[i] = body(state.document.annotations[i])
        }
    }

    private static func existing(_ ids: Set<Annotation.ID>, in document: ProjectDocument) -> Set<Annotation.ID> {
        ids.intersection(document.annotations.map(\.id))
    }

    static func reordered(_ items: [Annotation], ids: Set<Annotation.ID>, operation: ReorderOperation) -> [Annotation] {
        var result = items
        switch operation {
        case .bringToFront:
            result = items.filter { !ids.contains($0.id) } + items.filter { ids.contains($0.id) }
        case .sendToBack:
            result = items.filter { ids.contains($0.id) } + items.filter { !ids.contains($0.id) }
        case .bringForward:
            // Walk top-down; each selected item hops over the unselected one above it.
            var i = result.count - 2
            while i >= 0 {
                if ids.contains(result[i].id), !ids.contains(result[i + 1].id) {
                    result.swapAt(i, i + 1)
                }
                i -= 1
            }
        case .sendBackward:
            var i = 1
            while i < result.count {
                if ids.contains(result[i].id), !ids.contains(result[i - 1].id) {
                    result.swapAt(i, i - 1)
                }
                i += 1
            }
        }
        return result
    }
}

extension Annotation {
    /// Applies `patch` where it makes sense for this kind.
    func applying(_ patch: AnnotationPatch, scale: Double) -> Annotation {
        var copy = self
        if let color = patch.color { copy.style.color = color }
        if let width = patch.strokeWidth { copy.style.strokeWidth = width }
        if let opacity = patch.opacity { copy.style.opacity = min(max(opacity, 0), 1) }
        if let shadow = patch.shadow { copy.style.shadow = shadow }
        if let fill = patch.fill { copy.style.fill = fill }

        switch copy.kind {
        case .rectangle(var s):
            if let r = patch.cornerRadius { s.cornerRadius = r }
            copy.kind = .rectangle(s)
        case .filledRectangle(var s):
            if let r = patch.cornerRadius { s.cornerRadius = r }
            copy.kind = .filledRectangle(s)
        case .arrow(var s):
            if let style = patch.arrowStyle { s.arrowStyle = style }
            copy.kind = .arrow(s)
        case .text(var s):
            if let text = patch.text { s.text = text }
            if let style = patch.textStyle { s.textStyle = style }
            if let size = patch.fontSize { s.fontSize = size }
            if let alignment = patch.textAlignment { s.alignment = alignment }
            copy.kind = .text(s)
        case .counter(var s):
            if let style = patch.counterStyle { s.counterStyle = style }
            if let number = patch.counterNumber { s.number = number }
            if let width = patch.strokeWidth { s.diameter = max(5 * width, 24 * scale) }
            copy.kind = .counter(s)
        case .redaction(var s):
            if let method = patch.redactionMethod, method != s.method {
                s.method = method
                s.strength = method.defaultStrengthPoints * scale
            }
            if let strength = patch.redactionStrength { s.strength = strength }
            copy.kind = .redaction(s)
        case .spotlight(var s):
            if let r = patch.cornerRadius { s.cornerRadius = r }
            if let dim = patch.dimOpacity { s.dimOpacity = min(max(dim, 0), 1) }
            copy.kind = .spotlight(s)
        case .ellipse, .line, .pencil, .highlighter, .image:
            break
        }
        return copy
    }
}

// MARK: - Store

/// Observable owner of the editor state, with undo/redo.
///
/// **Undo model.** Each undo entry is a full snapshot of the `ProjectDocument`
/// (plus selection) *before* the change. Documents hold no pixels (assets are
/// referenced by `AssetID`), so snapshots are small. Depth: `undoLimit`
/// (default 200, oldest dropped). A new change clears the redo stack.
///
/// **Interaction coalescing.** A drag (move, resize, creation) is one undo step:
/// call `beginInteraction(_:)` on mouse-down, `apply` as often as needed while
/// dragging (no undo entries are recorded), then `endInteraction()` on
/// mouse-up (one entry, only if the document actually changed) or
/// `cancelInteraction()` (restores the pre-drag state, e.g. on Esc or a
/// too-small creation). Outside an interaction, every document-changing
/// `apply` is its own step. Selection/tool changes never create steps.
///
/// The app bridges this to the window's `NSUndoManager` / Edit menu via
/// `canUndo`, `undoActionName`, `undo()` etc.
@MainActor
@Observable
public final class EditorStore {
    public private(set) var state: EditorState
    public let undoLimit: Int

    private struct Snapshot: Sendable {
        var document: ProjectDocument
        var selection: Set<Annotation.ID>
    }

    private struct UndoEntry: Sendable {
        var snapshot: Snapshot
        var name: String
    }

    private struct Interaction: Sendable {
        var snapshot: Snapshot
        var name: String
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var interaction: Interaction?
    private var savedDocument: ProjectDocument

    public init(
        document: ProjectDocument,
        tool: AnnotationTool = .arrow,
        toolSettings: ToolSettings = ToolSettings(),
        undoLimit: Int = 200
    ) {
        self.state = EditorState(document: document, tool: tool, toolSettings: toolSettings)
        self.undoLimit = max(undoLimit, 1)
        self.savedDocument = document
    }

    // MARK: Read access

    public var document: ProjectDocument { state.document }
    public var selection: Set<Annotation.ID> { state.selection }
    public var tool: AnnotationTool { state.tool }
    public var toolSettings: ToolSettings { state.toolSettings }
    public var selectedAnnotations: [Annotation] { state.selectedAnnotations }
    public var nextCounterNumber: Int { state.nextCounterNumber }

    public var canUndo: Bool { !undoStack.isEmpty || hasInteractionChanges }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { interaction?.name ?? undoStack.last?.name }
    public var redoActionName: String? { redoStack.last?.name }
    public var isInteracting: Bool { interaction != nil }
    public var undoDepth: Int { undoStack.count }
    public var hasUnsavedChanges: Bool { state.document != savedDocument }

    private var hasInteractionChanges: Bool {
        guard let interaction else { return false }
        return interaction.snapshot.document != state.document
    }

    // MARK: Mutation

    public func apply(_ action: EditorAction) {
        let before = Snapshot(document: state.document, selection: state.selection)
        EditorReducer.reduce(&state, action)
        guard interaction == nil, state.document != before.document else { return }
        record(UndoEntry(snapshot: before, name: action.undoName))
    }

    /// Starts coalescing. Ignored if an interaction is already open.
    public func beginInteraction(_ name: String) {
        guard interaction == nil else { return }
        interaction = Interaction(snapshot: currentSnapshot, name: name)
    }

    /// Ends the open interaction, recording one undo step if the document changed.
    public func endInteraction() {
        guard let open = interaction else { return }
        interaction = nil
        if open.snapshot.document != state.document {
            record(UndoEntry(snapshot: open.snapshot, name: open.name))
        }
    }

    /// Ends the open interaction and reverts everything it changed.
    public func cancelInteraction() {
        guard let open = interaction else { return }
        interaction = nil
        restore(open.snapshot)
    }

    public func undo() {
        endInteraction()
        guard let entry = undoStack.popLast() else { return }
        redoStack.append(UndoEntry(snapshot: currentSnapshot, name: entry.name))
        restore(entry.snapshot)
    }

    public func redo() {
        endInteraction()
        guard let entry = redoStack.popLast() else { return }
        undoStack.append(UndoEntry(snapshot: currentSnapshot, name: entry.name))
        restore(entry.snapshot)
    }

    /// Call after writing the document to disk.
    public func markSaved() {
        savedDocument = state.document
    }

    /// Swaps in a different document (e.g. revert / reload) and clears history.
    public func replaceDocument(_ document: ProjectDocument) {
        interaction = nil
        undoStack.removeAll()
        redoStack.removeAll()
        state.document = document
        state.selection = []
        savedDocument = document
    }

    // MARK: Internals

    private var currentSnapshot: Snapshot {
        Snapshot(document: state.document, selection: state.selection)
    }

    private func record(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
    }

    private func restore(_ snapshot: Snapshot) {
        state.document = snapshot.document
        state.selection = snapshot.selection.intersection(snapshot.document.annotations.map(\.id))
    }
}
