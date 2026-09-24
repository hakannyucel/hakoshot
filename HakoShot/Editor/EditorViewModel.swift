import AppKit
import CoreGraphics
import HakoKit
import Observation
import os

/// What the option bar shows: the selected object's values when something is
/// selected, else the current tool's defaults (`nil` = no options, e.g. Move with
/// nothing selected).
struct EditorOptions: Equatable {
    /// Tool family whose controls are shown.
    var tool: AnnotationTool
    var isSelection: Bool
    var color: RGBAColor
    /// 0-based preset index (stroke width, or text size for text).
    var sizeIndex: Int
    var arrowStyle: ArrowStyle
    var textStyle: TextStyle
    var textAlignment: TextAlignmentMode
    var counterStyle: CounterStyle
    var counterStart: Int
    var redactionMethod: RedactionMethod
    var fill: Bool
    var shadow: Bool

    var usesTextSizes: Bool { tool == .text }
    var sizePoints: Double {
        usesTextSizes ? TextSizePreset.points(at: sizeIndex) : StrokeWidthPreset.points(at: sizeIndex)
    }
}

enum ZoomRequest: Equatable {
    case zoomIn, zoomOut, actualSize, fit
    case set(CGFloat)
}

/// Owns the `EditorStore` for one editor window and is the single entry point
/// for every mutation, so the canvas can invalidate exactly what changed
/// (`onStateChange` gets the state *before* each change).
@Observable
final class EditorViewModel {
    static let log = Logger(subsystem: Log.subsystem, category: "editor")

    let store: EditorStore
    let renderer: DocumentRenderer
    let baseImage: CGImage
    let captureMode: CaptureMode
    let captureDate: Date
    let settings: AppSettings
    /// File ⌘S writes to: the file the image came from, or the last save.
    var saveTarget: URL?
    /// Every image the document references (layers, image annotations,
    /// background image fill), by asset ID. Grows when the Background panel
    /// adds an image (`addAsset`).
    var assets: [AssetID: CGImage] { assetBox.all }
    @ObservationIgnored let assetBox: EditorAssetBox
    /// `.hakoshot` package this editor reads from / saves to (⌘S writes it
    /// instead of `saveTarget` when set). See `EditorViewModel+Project`.
    var projectURL: URL?
    /// History entry this document belongs to; every save refreshes its project.
    var historyID: UUID?

    // Mirrors of store state, updated only when they change so SwiftUI bars
    // don't re-render on every drag event.
    private(set) var tool: AnnotationTool
    private(set) var options: EditorOptions?
    private(set) var hasSelection = false
    private(set) var isDirty = false
    var zoom: CGFloat = 1
    private(set) var statusMessage: String?

    /// Called after every change with the previous state.
    @ObservationIgnored var onStateChange: ((EditorState) -> Void)?
    /// Ends an in-progress text edit (set by the canvas).
    @ObservationIgnored var commitTextEditing: (() -> Void)?
    @ObservationIgnored var zoomHandler: ((ZoomRequest) -> Void)?
    @ObservationIgnored var isEditingText: () -> Bool = { false }
    /// The editor window (sheets such as "Add Image…").
    @ObservationIgnored weak var hostWindow: NSWindow?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?

    // MARK: Crop / Background (WP5.1, WP5.2; see Crop/ and BackgroundPanel/)

    /// Open crop mode (`nil` = not cropping).
    var cropSession: CropSession? {
        didSet { if oldValue != cropSession { onDisplayChange?() } }
    }
    /// Background sidebar visible (B / capsule button).
    var showsBackgroundPanel = false
    /// Resize Image / Canvas Size popover (bottom bar size button, WP5.4).
    var showsSizePopover = false
    /// Bumped when presets change (they live in UserDefaults), so the panel reloads.
    var backgroundPresetsRevision = 0
    /// Style restored when the background is switched back on.
    @ObservationIgnored var lastBackgroundStyle: BackgroundStyle?
    /// Canvas redraw for view-only changes (crop session edits).
    @ObservationIgnored var onDisplayChange: (() -> Void)?
    @ObservationIgnored var backgroundCoalesceTask: Task<Void, Never>?

    convenience init(
        image: CGImage,
        scale: CGFloat,
        mode: CaptureMode,
        date: Date = .now,
        sourceURL: URL? = nil,
        settings: AppSettings = .shared
    ) {
        let asset = AssetID()
        let document = ProjectDocument(
            baseImage: asset,
            pixelWidth: image.width,
            pixelHeight: image.height,
            scale: Double(scale > 0 ? scale : 1),
            source: CaptureSourceInfo(mode: mode.fileNameToken, capturedAt: date, displayScale: Double(scale))
        )
        self.init(
            document: document, assets: [asset: image], baseImage: image,
            mode: mode, date: date, sourceURL: sourceURL, settings: settings
        )
    }

    /// Opens an existing document (e.g. a `.hakoshot` project). `baseImage` is
    /// the bottom layer's image (see `EditorViewModel+Project`).
    init(
        document: ProjectDocument,
        assets: [AssetID: CGImage],
        baseImage: CGImage,
        mode: CaptureMode,
        date: Date = .now,
        sourceURL: URL? = nil,
        settings: AppSettings = .shared
    ) {
        let box = EditorAssetBox(assets)
        // Settings › Annotate defaults (or the options used last).
        self.store = EditorStore(
            document: document,
            toolSettings: Self.usesAnnotateDefaults(settings) ? AnnotateDefaults.initialToolSettings(settings) : ToolSettings()
        )
        self.renderer = DocumentRenderer(redactionCache: RedactionCache()) { box.image(for: $0) }
        self.assetBox = box
        self.baseImage = baseImage
        self.captureMode = mode
        self.captureDate = date
        self.saveTarget = sourceURL
        self.settings = settings
        self.tool = store.tool
        refreshMirrors()
    }

    var document: ProjectDocument { store.document }
    var canvasScale: CGFloat { CGFloat(store.document.canvas.scale) }
    var selection: Set<Annotation.ID> { store.selection }

    // MARK: Mutation

    func perform(_ action: EditorAction) {
        let old = store.state
        store.apply(action)
        didChange(from: old)
    }

    func beginInteraction(_ name: String) {
        store.beginInteraction(name)
    }

    func endInteraction() {
        let old = store.state
        store.endInteraction()
        didChange(from: old)
    }

    func cancelInteraction() {
        let old = store.state
        store.cancelInteraction()
        didChange(from: old)
    }

    /// Groups several actions into one undo step (unless an interaction, such as
    /// a text edit, is already open — then they join it).
    func batch(_ name: String, _ body: () -> Void) {
        let owns = !store.isInteracting
        if owns { store.beginInteraction(name) }
        body()
        if owns { endInteraction() }
    }

    func undo() {
        commitTextEditing?()
        if cropSession != nil { cancelCrop() }
        let old = store.state
        store.undo()
        didChange(from: old)
    }

    func redo() {
        commitTextEditing?()
        if cropSession != nil { cancelCrop() }
        let old = store.state
        store.redo()
        didChange(from: old)
    }

    private func didChange(from old: EditorState) {
        refreshMirrors()
        onStateChange?(old)
    }

    func refreshMirrors() {
        let state = store.state
        if tool != state.tool { tool = state.tool }
        let newOptions = Self.options(for: state)
        if options != newOptions { options = newOptions }
        let selected = !state.selection.isEmpty
        if hasSelection != selected { hasSelection = selected }
        let dirty = store.hasUnsavedChanges
        if isDirty != dirty { isDirty = dirty }
    }

    // MARK: Tools

    func selectTool(_ newTool: AnnotationTool) {
        guard EditorShortcuts.enabledTools.contains(newTool) else { return }
        commitTextEditing?()
        switch newTool {
        case .crop:
            toggleCropMode()
            return
        case .background:
            toggleBackgroundPanel()
            return
        default:
            // Picking a drawing tool leaves crop mode without applying it.
            if cropSession != nil { cancelCrop() }
        }
        guard store.tool != newTool else { return }
        perform(.setTool(newTool))
    }

    // MARK: Options

    private func updateSettings(_ body: (inout ToolSettings) -> Void) {
        var tools = store.toolSettings
        body(&tools)
        perform(.setToolSettings(tools))
        if Self.usesAnnotateDefaults(settings) {
            AnnotateDefaults.remember(store.toolSettings, settings: settings)
        }
    }

    /// Unit tests host the app with the user's real defaults as `.shared`;
    /// editors made there neither read nor overwrite the remembered options.
    static func usesAnnotateDefaults(_ settings: AppSettings) -> Bool {
        !(AppInfo.isRunningTests && settings === AppSettings.shared)
    }

    func setColor(_ color: RGBAColor) {
        let target = options?.tool ?? tool
        batch("Change Color") {
            updateSettings { s in
                if target == .highlighter { s.highlighterColor = color } else { s.color = color }
            }
            restyleSelection(AnnotationPatch(color: color))
        }
    }

    /// Keys `1`–`6` and the size menu: stroke width, or text size for text.
    func setSizePreset(_ index: Int) {
        let index = min(max(index, 0), StrokeWidthPreset.points.count - 1)
        let target = options?.tool ?? tool
        let scale = Double(canvasScale)
        batch("Change Size") {
            updateSettings { s in
                if target == .text { s.textSizePresetIndex = index } else { s.setStrokePresetIndex(index, for: target) }
            }
            for annotation in store.selectedAnnotations {
                if case .text = annotation.kind {
                    perform(.update(textResized(annotation, fontSize: TextSizePreset.pixels(at: index, scale: scale))))
                } else {
                    let width = StrokeWidthPreset.pixels(at: index, scale: scale)
                    perform(.restyle([annotation.id], AnnotationPatch(strokeWidth: width)))
                }
            }
        }
    }

    func stepSize(by delta: Int) {
        let current = options?.sizeIndex ?? store.toolSettings.strokePresetIndex(for: tool)
        setSizePreset(current + delta)
    }

    func setArrowStyle(_ style: ArrowStyle) {
        batch("Change Arrow Style") {
            updateSettings { $0.arrowStyle = style }
            restyleSelection(AnnotationPatch(arrowStyle: style))
        }
    }

    func setTextStyle(_ style: TextStyle) {
        batch("Change Text Style") {
            updateSettings { $0.textStyle = style }
            for annotation in store.selectedAnnotations {
                guard case .text(var shape) = annotation.kind else { continue }
                let auto = TextAutoGrow.isAutoWidth(shape)
                shape.textStyle = style
                perform(.update(withText(annotation, shape: fitted(shape, autoWidth: auto))))
            }
        }
    }

    func setTextAlignment(_ alignment: TextAlignmentMode) {
        batch("Change Alignment") {
            updateSettings { $0.textAlignment = alignment }
            restyleSelection(AnnotationPatch(textAlignment: alignment))
        }
    }

    func setCounterStyle(_ style: CounterStyle) {
        batch("Change Counter Style") {
            updateSettings { $0.counterStyle = style }
            restyleSelection(AnnotationPatch(counterStyle: style))
        }
    }

    /// Start number (0 allowed). Existing counters are renumbered from it.
    func setCounterStart(_ start: Int) {
        let start = max(0, start)
        if store.document.annotations.contains(where: { $0.counter != nil }) {
            perform(.renumberCounters(startingAt: start))
        } else {
            updateSettings { $0.counterStartNumber = start }
        }
    }

    func setRedactionMethod(_ method: RedactionMethod) {
        batch("Change Redaction") {
            updateSettings { $0.redactionMethod = method }
            restyleSelection(AnnotationPatch(redactionMethod: method))
        }
    }

    func setFill(_ on: Bool) {
        let color = options?.color ?? store.toolSettings.color
        let fill: RGBAColor? = on ? color.withAlpha(EditorMetrics.shapeFillOpacity) : nil
        batch("Change Fill") {
            updateSettings { $0.shapeFill = fill }
            restyleSelection(AnnotationPatch(fill: .some(fill)))
        }
    }

    func setShadow(_ on: Bool) {
        batch("Change Shadow") {
            updateSettings { $0.shadow = on }
            restyleSelection(AnnotationPatch(shadow: on))
        }
    }

    /// NSColorPanel sends a stream of changes; they become one undo step.
    func setColorCoalesced(_ color: RGBAColor) {
        if !store.isInteracting { store.beginInteraction("Change Color") }
        setColor(color)
        coalesceTask?.cancel()
        coalesceTask = Task { [weak self] in
            try? await Task.sleep(for: EditorMetrics.colorPanelCoalesce)
            guard !Task.isCancelled, let self, !self.isEditingText() else { return }
            self.endInteraction()
        }
    }

    private func restyleSelection(_ patch: AnnotationPatch) {
        let ids = store.selection
        guard !ids.isEmpty else { return }
        perform(.restyle(ids, patch))
    }

    // MARK: Text helpers

    /// Widest a text box starting at `x` may auto-grow (to the canvas's right edge).
    func maxTextWidth(from x: CGFloat) -> CGFloat {
        max(CGFloat(store.document.canvas.width) - x, 0)
    }

    func fitted(_ shape: TextShape, autoWidth: Bool) -> TextShape {
        var copy = shape
        copy.frame = TextAutoGrow.fittedFrame(for: shape, autoWidth: autoWidth, maxWidth: maxTextWidth(from: shape.frame.minX))
        return copy
    }

    func withText(_ annotation: Annotation, shape: TextShape) -> Annotation {
        var copy = annotation
        copy.kind = .text(shape)
        return copy
    }

    /// New font size; a fixed-width box scales its width along with it.
    func textResized(_ annotation: Annotation, fontSize: Double) -> Annotation {
        guard case .text(var shape) = annotation.kind, shape.fontSize > 0 else { return annotation }
        let auto = TextAutoGrow.isAutoWidth(shape)
        if !auto { shape.frame.size.width *= fontSize / shape.fontSize }
        shape.fontSize = fontSize
        return withText(annotation, shape: fitted(shape, autoWidth: auto))
    }

    /// After a handle drag: width never below the widest word, height refit.
    func textRefitted(_ annotation: Annotation) -> Annotation {
        guard case .text(let shape) = annotation.kind else { return annotation }
        return withText(annotation, shape: fitted(shape, autoWidth: false))
    }

    // MARK: Object commands

    func deleteSelection() {
        guard !store.selection.isEmpty else { return }
        perform(.deleteSelection)
    }

    func duplicateSelection() {
        guard !store.selection.isEmpty else { return }
        let d = EditorMetrics.duplicateOffset * canvasScale
        perform(.duplicate(store.selection, offset: CGVector(dx: d, dy: d)))
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        guard !store.selection.isEmpty else { return }
        perform(.move(store.selection, by: CGVector(dx: dx * canvasScale, dy: dy * canvasScale)))
    }

    func selectAll() {
        perform(.selectAll)
    }

    func clearSelection() {
        guard !store.selection.isEmpty else { return }
        perform(.clearSelection)
    }

    func reorderSelection(_ operation: ReorderOperation) {
        guard !store.selection.isEmpty else { return }
        perform(.reorder(store.selection, operation))
    }

    // MARK: Object clipboard

    static let annotationsPasteboardType = NSPasteboard.PasteboardType("com.hakanyucel.hakoshot.annotations")

    /// ⌘C with a selection: the objects, for ⌘V in any editor window. A
    /// selected image also goes on the pasteboard as PNG (other apps, and
    /// editors that don't have its asset).
    @discardableResult
    func copySelectionToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        let items = store.selectedAnnotations
        guard !items.isEmpty, let data = try? JSONEncoder().encode(items) else { return false }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.annotationsPasteboardType)
        if case .image(let shape)? = items.last(where: { $0.kind.tag == .image })?.kind,
           let image = assetBox.image(for: shape.assetID),
           let png = try? ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions.defaults(for: .png, scale: canvasScale)) {
            pasteboard.setData(png, forType: .png)
        }
        return true
    }

    /// ⌘V: pastes copied objects (offset when the originals are still here).
    @discardableResult
    func pasteFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard let data = pasteboard.data(forType: Self.annotationsPasteboardType),
              let decoded = try? JSONDecoder().decode([Annotation].self, from: data)
        else { return false }
        // Images whose pixels this editor doesn't have can't be pasted as
        // objects (the PNG copy then goes through `pasteImage`).
        let items = decoded.filter { annotation in
            guard case .image(let shape) = annotation.kind else { return true }
            return assetBox.image(for: shape.assetID) != nil
        }
        guard !items.isEmpty else { return false }
        commitTextEditing?()
        let overlaps = items.contains { store.document.index(of: $0.id) != nil }
        let d = overlaps ? EditorMetrics.duplicateOffset * canvasScale : 0
        var next = store.nextCounterNumber
        var ids = Set<Annotation.ID>()
        batch("Paste") {
            for original in items {
                var copy = original.translated(by: CGVector(dx: d, dy: d))
                copy.id = UUID()
                if case .counter(var shape) = copy.kind {
                    shape.number = next
                    next += 1
                    copy.kind = .counter(shape)
                }
                perform(.add(copy, select: false))
                ids.insert(copy.id)
            }
            perform(.select(ids))
        }
        return true
    }

    // MARK: Status

    func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: EditorMetrics.statusDuration)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    // MARK: Options derivation

    static func tool(for kind: Annotation.KindTag) -> AnnotationTool? {
        switch kind {
        case .rectangle: .rectangle
        case .filledRectangle: .filledRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrow
        case .text: .text
        case .pencil: .pencil
        case .highlighter: .highlighter
        case .counter: .counter
        case .redaction: .redaction
        case .spotlight: .spotlight
        case .image: nil
        }
    }

    static func nearestIndex(_ presets: [Double], to value: Double) -> Int {
        presets.indices.min { abs(presets[$0] - value) < abs(presets[$1] - value) } ?? 0
    }

    static func options(for state: EditorState) -> EditorOptions? {
        let settings = state.toolSettings
        let scale = state.document.canvas.scale
        let selected = state.selectedAnnotations.last { tool(for: $0.kind.tag) != nil }
        guard let target = selected.flatMap({ tool(for: $0.kind.tag) }) ?? (state.tool.createsAnnotation ? state.tool : nil) else {
            return nil
        }
        var options = EditorOptions(
            tool: target,
            isSelection: selected != nil,
            color: target == .highlighter ? settings.highlighterColor : settings.color,
            sizeIndex: target == .text ? settings.textSizePresetIndex : settings.strokePresetIndex(for: target),
            arrowStyle: settings.arrowStyle,
            textStyle: settings.textStyle,
            textAlignment: settings.textAlignment,
            counterStyle: settings.counterStyle,
            counterStart: settings.counterStartNumber,
            redactionMethod: settings.redactionMethod,
            fill: settings.shapeFill != nil,
            shadow: settings.shadow
        )
        guard let annotation = selected else { return options }
        options.color = annotation.style.color
        options.shadow = annotation.style.shadow
        options.fill = annotation.style.fill != nil
        let strokePoints = annotation.style.strokeWidth / max(scale, 0.0001)
        options.sizeIndex = nearestIndex(StrokeWidthPreset.points, to: strokePoints)
        switch annotation.kind {
        case .text(let s):
            options.sizeIndex = nearestIndex(TextSizePreset.points, to: s.fontSize / max(scale, 0.0001))
            options.textStyle = s.textStyle
            options.textAlignment = s.alignment
        case .arrow(let s):
            options.arrowStyle = s.arrowStyle
        case .counter(let s):
            options.counterStyle = s.counterStyle
        case .redaction(let s):
            options.redactionMethod = s.method
        default:
            break
        }
        return options
    }
}
