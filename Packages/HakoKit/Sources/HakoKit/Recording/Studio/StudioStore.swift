import Foundation
import Observation

// MARK: - State

/// Everything the Studio reducer operates on. Only `project` is undoable;
/// the zoom selection is restored alongside it.
public struct StudioEditorState: Sendable, Hashable {
    public var project: StudioProject
    public var selectedZoomSegment: ZoomSegment.ID?

    public init(project: StudioProject, selectedZoomSegment: ZoomSegment.ID? = nil) {
        self.project = project
        self.selectedZoomSegment = selectedZoomSegment
    }

    public var selectedSegment: ZoomSegment? {
        guard let id = selectedZoomSegment else { return nil }
        return project.zoom.segments.first { $0.id == id }
    }
}

// MARK: - Actions

/// Every Studio edit. Project-changing actions become undo steps (coalesced
/// while an interaction is open, see `StudioStore`). Values are clamped by
/// the reducer (`normalized()`).
public enum StudioAction: Sendable, Hashable {
    // Timeline (source seconds)
    case setTrim(EditTimeRange?)
    case addCut(EditTimeRange)
    case removeCut(EditTimeRange)
    case setCuts([EditTimeRange])

    // Canvas
    case setAspectRatio(RecordingAspectRatio)
    case setOutputHeight(Int)
    case setBackground(BackgroundStyle)
    case setBackgroundFill(BackgroundFill)
    case setPadding(Double)
    case setCornerRadius(Double)
    case setShadow(BackgroundShadow)

    // Cursor
    case setCursor(StudioCursorSettings)
    case setCursorVisible(Bool)
    case setCursorScale(Double)
    case setCursorSmoothing(Double)
    case setHideCursorWhenIdle(Bool)
    case setClickEffect(Bool)

    // Zoom
    case setAutoZoom(Bool)
    case setDefaultZoomScale(Double)
    case setZoomSpeed(StudioZoomSpeed)
    /// Adds (as manual) and selects it.
    case addZoomSegment(ZoomSegment)
    /// Replaces the segment with the same ID; it becomes manual.
    case updateZoomSegment(ZoomSegment)
    case removeZoomSegment(ZoomSegment.ID)
    /// Swaps every auto segment for `segments` (marked auto); manual ones stay.
    case replaceAutoZoomSegments([ZoomSegment])
    /// Not undoable on its own.
    case selectZoomSegment(ZoomSegment.ID?)

    // Other sections
    case setMotionBlur(StudioMotionBlur)
    case setCamera(StudioCameraSettings)
    case setKeystrokes(StudioKeystrokeSettings)
    case setAudio(VideoEditAudio)
    case setExport(StudioExportSettings)

    /// Name for the Undo/Redo menu items.
    public var undoName: String {
        switch self {
        case .setTrim: "Trim"
        case .addCut: "Cut"
        case .removeCut, .setCuts: "Edit Cuts"
        case .setAspectRatio: "Aspect Ratio"
        case .setOutputHeight: "Output Size"
        case .setBackground, .setBackgroundFill: "Background"
        case .setPadding: "Padding"
        case .setCornerRadius: "Corner Radius"
        case .setShadow: "Shadow"
        case .setCursor, .setCursorVisible, .setCursorScale, .setCursorSmoothing, .setHideCursorWhenIdle: "Cursor"
        case .setClickEffect: "Click Effect"
        case .setAutoZoom, .setDefaultZoomScale, .setZoomSpeed: "Zoom"
        case .addZoomSegment: "Add Zoom"
        case .updateZoomSegment: "Edit Zoom"
        case .removeZoomSegment: "Delete Zoom"
        case .replaceAutoZoomSegments: "Auto Zoom"
        case .selectZoomSegment: "Select"
        case .setMotionBlur: "Motion Blur"
        case .setCamera: "Camera"
        case .setKeystrokes: "Keystrokes"
        case .setAudio: "Audio"
        case .setExport: "Export Settings"
        }
    }
}

// MARK: - Reducer

/// The pure Studio reducer. Tests drive it directly.
public enum StudioReducer {
    public static func reduce(_ state: StudioEditorState, _ action: StudioAction) -> StudioEditorState {
        var copy = state
        reduce(&copy, action)
        return copy
    }

    public static func reduce(_ state: inout StudioEditorState, _ action: StudioAction) {
        if case .selectZoomSegment(let id) = action {
            state.selectedZoomSegment = id.flatMap { id in state.project.zoom.segments.contains { $0.id == id } ? id : nil }
            return
        }
        var p = state.project
        switch action {
        case .setTrim(let range):
            p.edit.trim = range.map { normalizedRange($0, duration: p.source.duration) }
            if let trim = p.edit.trim, trim.start <= 0, trim.end >= p.source.duration { p.edit.trim = nil }
        case .addCut(let range):
            let cut = normalizedRange(range, duration: p.source.duration)
            guard !cut.isEmpty else { return }
            p.edit.cuts = mergedCuts(p.edit.cuts + [cut])
        case .removeCut(let range):
            p.edit.cuts.removeAll { $0 == range }
        case .setCuts(let cuts):
            p.edit.cuts = mergedCuts(cuts.map { normalizedRange($0, duration: p.source.duration) }.filter { !$0.isEmpty })

        case .setAspectRatio(let ratio):
            p.canvas.aspectRatio = ratio
        case .setOutputHeight(let height):
            p.canvas.outputHeight = height
        case .setBackground(let style):
            p.canvas.background = style
        case .setBackgroundFill(let fill):
            p.canvas.background.fill = fill
        case .setPadding(let value):
            p.canvas.padding = value
        case .setCornerRadius(let value):
            p.canvas.cornerRadius = value
        case .setShadow(let shadow):
            p.canvas.shadow = shadow

        case .setCursor(let cursor):
            p.cursor = cursor
        case .setCursorVisible(let visible):
            p.cursor.visible = visible
        case .setCursorScale(let scale):
            p.cursor.scale = scale
        case .setCursorSmoothing(let smoothing):
            p.cursor.smoothing = smoothing
        case .setHideCursorWhenIdle(let hide):
            p.cursor.hideWhenIdle = hide
        case .setClickEffect(let on):
            p.cursor.clickEffect = on

        case .setAutoZoom(let on):
            p.zoom.auto = on
        case .setDefaultZoomScale(let scale):
            p.zoom.defaultScale = scale
        case .setZoomSpeed(let speed):
            p.zoom.speed = speed
        case .addZoomSegment(var segment):
            guard !p.zoom.segments.contains(where: { $0.id == segment.id }) else { return }
            segment.isManual = true
            p.zoom.segments.append(segment)
            state.selectedZoomSegment = segment.id
        case .updateZoomSegment(var segment):
            guard let i = p.zoom.segments.firstIndex(where: { $0.id == segment.id }) else { return }
            segment.isManual = true
            p.zoom.segments[i] = segment
        case .removeZoomSegment(let id):
            p.zoom.segments.removeAll { $0.id == id }
            if state.selectedZoomSegment == id { state.selectedZoomSegment = nil }
        case .replaceAutoZoomSegments(let segments):
            let manual = p.zoom.segments.filter(\.isManual)
            p.zoom.segments = manual + segments.map { var s = $0; s.isManual = false; return s }
        case .selectZoomSegment:
            return

        case .setMotionBlur(let blur):
            p.motionBlur = blur
        case .setCamera(let camera):
            p.camera = camera
        case .setKeystrokes(let keys):
            p.keystrokes = keys
        case .setAudio(let audio):
            p.audio = audio
        case .setExport(let export):
            p.export = export
        }
        p = p.normalized()
        if let id = state.selectedZoomSegment, !p.zoom.segments.contains(where: { $0.id == id }) {
            state.selectedZoomSegment = nil
        }
        state.project = p
    }

    // MARK: Helpers

    private static func normalizedRange(_ range: EditTimeRange, duration: Double) -> EditTimeRange {
        let limit = duration.isFinite ? max(duration, 0) : 0
        let a = clampFinite(min(range.start, range.end), 0, limit, fallback: 0)
        let b = clampFinite(max(range.start, range.end), 0, limit, fallback: 0)
        return EditTimeRange(start: a, end: b)
    }

    private static func mergedCuts(_ cuts: [EditTimeRange]) -> [EditTimeRange] {
        var merged: [EditTimeRange] = []
        for cut in cuts.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1].end = max(last.end, cut.end)
            } else {
                merged.append(cut)
            }
        }
        return merged
    }
}

// MARK: - Store

/// Observable owner of the Studio editor state, with undo/redo; same model
/// as `EditorStore`: each entry is a snapshot of the project (no pixels) taken
/// before the change, depth `undoLimit`, a new change clears redo. Slider
/// drags coalesce into one step between `beginInteraction(_:)` and
/// `endInteraction()` (or `cancelInteraction()` to revert).
@MainActor
@Observable
public final class StudioStore {
    public private(set) var state: StudioEditorState
    public let undoLimit: Int

    private struct Snapshot: Sendable {
        var project: StudioProject
        var selectedZoomSegment: ZoomSegment.ID?
    }

    private struct UndoEntry: Sendable {
        var snapshot: Snapshot
        var name: String
    }

    private var undoStack: [UndoEntry] = []
    private var redoStack: [UndoEntry] = []
    private var interaction: UndoEntry?
    private var savedProject: StudioProject

    public init(project: StudioProject, undoLimit: Int = 200) {
        self.state = StudioEditorState(project: project)
        self.undoLimit = max(undoLimit, 1)
        self.savedProject = project
    }

    // MARK: Read access

    public var project: StudioProject { state.project }
    public var selectedZoomSegment: ZoomSegment.ID? { state.selectedZoomSegment }

    public var canUndo: Bool { !undoStack.isEmpty || hasInteractionChanges }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoActionName: String? { interaction?.name ?? undoStack.last?.name }
    public var redoActionName: String? { redoStack.last?.name }
    public var isInteracting: Bool { interaction != nil }
    public var undoDepth: Int { undoStack.count }
    public var hasUnsavedChanges: Bool { state.project != savedProject }

    private var hasInteractionChanges: Bool {
        guard let interaction else { return false }
        return interaction.snapshot.project != state.project
    }

    // MARK: Mutation

    public func apply(_ action: StudioAction) {
        let before = currentSnapshot
        StudioReducer.reduce(&state, action)
        guard interaction == nil, state.project != before.project else { return }
        record(UndoEntry(snapshot: before, name: action.undoName))
    }

    /// Starts coalescing. Ignored if an interaction is already open.
    public func beginInteraction(_ name: String) {
        guard interaction == nil else { return }
        interaction = UndoEntry(snapshot: currentSnapshot, name: name)
    }

    /// Ends the open interaction, recording one step if the project changed.
    public func endInteraction() {
        guard let open = interaction else { return }
        interaction = nil
        if open.snapshot.project != state.project { record(open) }
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

    /// Call after writing the project to disk.
    public func markSaved() {
        savedProject = state.project
    }

    /// Swaps in a different project (revert / reload) and clears history.
    public func replaceProject(_ project: StudioProject) {
        interaction = nil
        undoStack.removeAll()
        redoStack.removeAll()
        state = StudioEditorState(project: project)
        savedProject = project
    }

    // MARK: Internals

    private var currentSnapshot: Snapshot {
        Snapshot(project: state.project, selectedZoomSegment: state.selectedZoomSegment)
    }

    private func record(_ entry: UndoEntry) {
        undoStack.append(entry)
        if undoStack.count > undoLimit {
            undoStack.removeFirst(undoStack.count - undoLimit)
        }
        redoStack.removeAll()
    }

    private func restore(_ snapshot: Snapshot) {
        state.project = snapshot.project
        let id = snapshot.selectedZoomSegment
        state.selectedZoomSegment = id.flatMap { id in snapshot.project.zoom.segments.contains { $0.id == id } ? id : nil }
    }
}
