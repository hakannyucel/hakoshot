import AppKit
import HakoKit

/// The editor canvas (plan §1.2: AppKit `NSView`). It is the scroll view's
/// document view: the image at 100 % plus a gray margin, magnified by the
/// enclosing `NSScrollView`. Draws through `DocumentRenderer.drawCanvas` (the
/// same code path as export), then selection chrome on top, and routes mouse
/// events to the active tool controller.
final class CanvasView: NSView, CanvasToolHost {
    let model: EditorViewModel
    private(set) var geometry: CanvasGeometry
    /// Runs editor commands (copy, delete …) owned by the window controller.
    var onCommand: ((EditorCommand) -> Bool)?

    var marqueeRect: CGRect? {
        didSet {
            guard oldValue != marqueeRect else { return }
            invalidateCanvasRect([oldValue, marqueeRect].compactMap { $0 }.reduce(CGRect.null) { $0.union($1) }, pad: 4)
        }
    }

    var isDragging = false {
        didSet {
            guard oldValue != isDragging else { return }
            invalidateSelectionChrome()
        }
    }

    private var tools: [AnnotationTool: CanvasTool] = [:]
    private var activeTool: CanvasTool?
    private var lastDragPoint: CGPoint?
    private(set) var textEditor: TextEditingController?
    private let imageHasAlpha: Bool
    private(set) var display: CanvasDisplay
    private let cropInteraction = CropInteraction()
    /// Crop rect (view points) drawn last, for partial invalidation.
    private var drawnCropRect: CGRect?

    init(model: EditorViewModel) {
        self.model = model
        let display = CanvasDisplay.mode(for: model.document, cropping: model.isCropping)
        self.display = display
        self.geometry = CanvasDisplay.geometry(for: model.document, mode: display) { model.renderer.outputLayout(of: model.document) }
        switch model.baseImage.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: imageHasAlpha = false
        default: imageHasAlpha = true
        }
        super.init(frame: CGRect(origin: .zero, size: geometry.viewSize))
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        model.onStateChange = { [weak self] old in self?.stateDidChange(from: old) }
        model.commitTextEditing = { [weak self] in self?.textEditor?.end() }
        model.isEditingText = { [weak self] in self?.textEditor != nil }
        model.onDisplayChange = { [weak self] in self?.cropSessionDidChange() }
        registerForDraggedTypes(CanvasDropSupport.acceptedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }
    var pixelsPerScreenPoint: CGFloat { geometry.pixelsPerScreenPoint(magnification: magnification) }
    var isEditingText: Bool { textEditor != nil }

    /// Last crop drag event (⌘ toggling snapping mid-drag replays it).
    private var lastCropEvent: NSEvent?

    private func outputPoint(for event: NSEvent) -> CGPoint {
        geometry.outputPoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func canvasPoint(for event: NSEvent) -> CGPoint {
        geometry.canvasPoint(fromView: convert(event.locationInWindow, from: nil))
    }

    private func tool(for kind: AnnotationTool) -> CanvasTool {
        if let existing = tools[kind] { return existing }
        let made: CanvasTool = switch kind {
        case .move, .crop, .background: SelectionTool(allowsMarquee: true)
        case .text: TextTool()
        default: CreationTool(tool: kind)
        }
        tools[kind] = made
        return made
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if let textEditor {
            // A click outside the text box ends editing (clicks inside go to the text view).
            textEditor.end()
            return
        }
        window?.makeFirstResponder(self)
        if model.isCropping {
            cropInteraction.mouseDown(at: outputPoint(for: event), model: model, pixelsPerPoint: pixelsPerScreenPoint)
            return
        }
        let point = canvasPoint(for: event)
        let current = tool(for: model.tool)
        activeTool = current
        lastDragPoint = point
        current.mouseDown(at: point, event: event, host: self)
    }

    override func mouseDragged(with event: NSEvent) {
        if cropInteraction.isDragging {
            autoscroll(with: event)
            lastCropEvent = event
            cropInteraction.mouseDragged(to: outputPoint(for: event), event: event, model: model, pixelsPerPoint: pixelsPerScreenPoint)
            return
        }
        guard let activeTool else { return }
        autoscroll(with: event)
        let point = canvasPoint(for: event)
        lastDragPoint = point
        activeTool.mouseDragged(to: point, event: event, host: self)
    }

    override func mouseUp(with event: NSEvent) {
        if cropInteraction.isDragging {
            cropInteraction.mouseUp(model: model)
            lastCropEvent = nil
            updateCursor(for: event)
            return
        }
        guard let activeTool else { return }
        self.activeTool = nil
        activeTool.mouseUp(at: canvasPoint(for: event), event: event, host: self)
        lastDragPoint = nil
        updateCursor(for: event)
    }

    /// ⇧ pressed / released mid-drag re-applies the constraint without moving the mouse.
    override func flagsChanged(with event: NSEvent) {
        if cropInteraction.isDragging, let last = lastCropEvent,
           let replay = NSEvent.mouseEvent(
               with: .leftMouseDragged, location: last.locationInWindow, modifierFlags: event.modifierFlags,
               timestamp: event.timestamp, windowNumber: last.windowNumber, context: nil,
               eventNumber: 0, clickCount: 1, pressure: 1
           ) {
            cropInteraction.mouseDragged(to: outputPoint(for: replay), event: replay, model: model, pixelsPerPoint: pixelsPerScreenPoint)
        }
        if let activeTool, let lastDragPoint {
            activeTool.mouseDragged(to: lastDragPoint, event: event, host: self)
        }
        super.flagsChanged(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        updateCursor(for: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        updateCursor(for: event)
    }

    private func updateCursor(for event: NSEvent) {
        guard activeTool == nil, !cropInteraction.isDragging else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let session = model.cropSession {
            cropInteraction.cursor(at: geometry.outputPoint(fromView: viewPoint), session: session, pixelsPerPoint: pixelsPerScreenPoint).set()
            return
        }
        if let textEditor, textEditor.textView.frame.contains(viewPoint) { return }
        tool(for: model.tool).cursor(at: geometry.canvasPoint(fromView: viewPoint), host: self).set()
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        if !handleKey(event) { super.keyDown(with: event) }
    }

    /// Single-key shortcuts; never while a text box is being edited.
    func handleKey(_ event: NSEvent) -> Bool {
        guard textEditor == nil, let command = EditorShortcuts.canvasKey(for: EditorKeyInput(event: event)) else { return false }
        return perform(command)
    }

    func perform(_ command: EditorCommand) -> Bool {
        if model.isCropping {
            switch command {
            case .escape:
                if !cropInteraction.cancel(model: model) { model.cancelCrop() }
                return true
            case .editSelectedText:
                model.applyCrop()
                return true
            case .deleteSelection, .nudge, .sizePreset, .increaseSize, .decreaseSize:
                return true
            default:
                break
            }
        }
        switch command {
        case .escape:
            escape()
            return true
        case .editSelectedText:
            guard model.selection.count == 1, let id = model.selection.first,
                  model.document.annotation(withID: id)?.kind.tag == .text
            else { return false }
            beginTextEditing(id, isNew: false)
            return true
        default:
            return onCommand?(command) ?? false
        }
    }

    /// Esc: cancel a drag, else end text editing, else deselect.
    func escape() {
        if let activeTool, activeTool.cancel(host: self) {
            self.activeTool = nil
            return
        }
        if let textEditor {
            textEditor.end()
            return
        }
        model.clearSelection()
    }

    // MARK: Text editing

    func beginTextEditing(_ id: Annotation.ID, isNew: Bool) {
        textEditor?.end()
        guard let editor = TextEditingController(annotationID: id, isNew: isNew, canvas: self, model: model) else { return }
        textEditor = editor
        editor.begin()
        invalidateSelectionChrome()
    }

    func textEditingDidEnd(_ editor: TextEditingController) {
        guard textEditor === editor else { return }
        textEditor = nil
        needsDisplay = true
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if model.isCropping { return nil }
        textEditor?.end()
        let point = canvasPoint(for: event)
        let menu = NSMenu()
        if let hit = HitTesting.topmostAnnotation(at: point, in: model.document.annotations, pixelsPerPoint: pixelsPerScreenPoint) {
            if !model.selection.contains(hit) { model.perform(.select([hit])) }
            if model.document.annotation(withID: hit)?.kind.tag == .text {
                menu.addItem(ActionMenuItem("Edit Text") { [weak self] in self?.beginTextEditing(hit, isNew: false) })
                menu.addItem(.separator())
            }
            menu.addItem(commandItem("Copy", .copy))
            menu.addItem(commandItem("Cut", .cut))
            menu.addItem(commandItem("Duplicate", .duplicate))
            menu.addItem(commandItem("Delete", .deleteSelection))
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem("Bring to Front") { [weak self] in self?.model.reorderSelection(.bringToFront) })
            menu.addItem(ActionMenuItem("Bring Forward") { [weak self] in self?.model.reorderSelection(.bringForward) })
            menu.addItem(ActionMenuItem("Send Backward") { [weak self] in self?.model.reorderSelection(.sendBackward) })
            menu.addItem(ActionMenuItem("Send to Back") { [weak self] in self?.model.reorderSelection(.sendToBack) })
            if model.document.annotation(withID: hit)?.counter != nil {
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Renumber Counters") { [weak self] in
                    guard let self else { return }
                    self.model.perform(.renumberCounters(startingAt: self.model.store.toolSettings.counterStartNumber))
                })
            }
        } else {
            menu.addItem(commandItem("Copy Image", .copyImage))
            menu.addItem(commandItem("Save", .save))
            menu.addItem(commandItem("Save As…", .saveAs))
            menu.addItem(.separator())
            let paste = commandItem("Paste", .paste)
            paste.isEnabled = NSPasteboard.general.data(forType: EditorViewModel.annotationsPasteboardType) != nil
                || EditorViewModel.hasImage(on: .general)
            menu.addItem(paste)
            menu.addItem(commandItem("Select All", .selectAll))
            menu.addItem(.separator())
            menu.addItem(commandItem("Add Image…", .addImage))
            menu.addItem(commandItem("Add New Screenshot", .addScreenshot))
            menu.addItem(ActionMenuItem("Resize Image / Canvas…") { [weak self] in self?.model.showsSizePopover = true })
            menu.addItem(.separator())
            menu.addItem(commandItem("Zoom to Fit", .zoomToFit))
            menu.addItem(commandItem("Actual Size", .zoomActualSize))
        }
        menu.autoenablesItems = false
        return menu
    }

    private func commandItem(_ title: String, _ command: EditorCommand) -> NSMenuItem {
        ActionMenuItem(title) { [weak self] in _ = self?.onCommand?(command) }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let imageRect = geometry.imageRect
        let magnification = magnification
        let document = model.document

        // Soft shadow + white base under the image.
        if !imageRect.insetBy(dx: 2, dy: 2).contains(dirtyRect) {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -EditorMetrics.imageShadowOffsetY),
                blur: EditorMetrics.imageShadowBlur,
                color: NSColor.black.withAlphaComponent(EditorMetrics.imageShadowOpacity).cgColor
            )
            context.setFillColor(NSColor.white.cgColor)
            context.fill(imageRect)
            context.restoreGState()
        }
        if display == .output, document.background?.fill == .transparent {
            drawCheckerboard(in: imageRect.intersection(dirtyRect), context: context)
        } else if imageHasAlpha || Self.hasUncoveredArea(document) {
            let content = display == .crop ? imageRect : geometry.viewRect(fromCanvas: document.visibleRect)
            drawCheckerboard(in: content.intersection(dirtyRect), context: context)
        }

        // The document, in displayed pixel space.
        context.saveGState()
        context.clip(to: imageRect)
        context.translateBy(x: geometry.margin, y: geometry.margin)
        context.scaleBy(x: 1 / geometry.scale, y: 1 / geometry.scale)
        let options = DocumentRenderer.Options(
            dirtyRect: geometry.canvasRect(fromView: dirtyRect),
            baseScale: Double(window?.backingScaleFactor ?? 2)
        )
        switch display {
        case .canvas:
            model.renderer.drawCanvas(document, in: context, options: options)
        case .crop:
            context.concatenate(geometry.transform)
            model.renderer.drawCanvas(document, in: context, options: options)
        case .output:
            model.renderer.drawOutput(document, in: context, options: options)
        }
        context.restoreGState()

        if let session = model.cropSession, display == .crop {
            let rect = geometry.viewRect(fromOutput: session.rect)
            CropOverlayPainter.draw(rect: rect, imageRect: imageRect, magnification: magnification, context: context)
            drawnCropRect = rect
            return
        }
        drawSelectionChrome(context: context, magnification: magnification)
        if let marqueeRect {
            let rect = geometry.viewRect(fromCanvas: marqueeRect)
            context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(EditorMetrics.marqueeFillOpacity).cgColor)
            context.fill(rect)
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / magnification)
            context.stroke(rect)
        }
    }

    /// Combined images / a grown canvas leave transparent areas (and added
    /// images may have alpha): show the checkerboard behind them.
    static func hasUncoveredArea(_ document: ProjectDocument) -> Bool {
        if document.annotations.contains(where: { $0.kind.tag == .image }) { return true }
        let canvas = document.canvas.rect
        return !document.layers.contains { $0.frame.contains(canvas) }
    }

    private func drawCheckerboard(in rect: CGRect, context: CGContext) {
        guard !rect.isNull, !rect.isEmpty, rect.width > 0 else { return }
        let size = EditorMetrics.checkerSize
        let origin = geometry.imageRect.origin
        context.saveGState()
        context.setFillColor(EditorMetrics.checkerLight.cgColor)
        context.fill(rect)
        context.setFillColor(EditorMetrics.checkerDark.cgColor)
        let startColumn = Int(((rect.minX - origin.x) / size).rounded(.down))
        let endColumn = Int(((rect.maxX - origin.x) / size).rounded(.up))
        let startRow = Int(((rect.minY - origin.y) / size).rounded(.down))
        let endRow = Int(((rect.maxY - origin.y) / size).rounded(.up))
        context.clip(to: rect)
        for row in startRow..<max(endRow, startRow) {
            for column in startColumn..<max(endColumn, startColumn) where (row + column) % 2 == 0 {
                context.fill(CGRect(x: origin.x + CGFloat(column) * size, y: origin.y + CGFloat(row) * size, width: size, height: size))
            }
        }
        context.restoreGState()
    }

    private func drawSelectionChrome(context: CGContext, magnification: CGFloat) {
        let accent = NSColor.controlAccentColor.cgColor
        let selected = model.store.selectedAnnotations
        let editingID = textEditor?.annotationID
        context.saveGState()
        context.setStrokeColor(accent)
        context.setLineWidth(EditorMetrics.selectionOutlineWidth / magnification)
        for annotation in selected where annotation.id != editingID && HandleGeometry.drawsOutline(for: annotation) {
            context.stroke(geometry.viewRect(fromCanvas: annotation.bounds))
        }
        if let editingID, let annotation = model.document.annotation(withID: editingID) {
            context.setLineDash(phase: 0, lengths: [4 / magnification, 3 / magnification])
            context.stroke(geometry.viewRect(fromCanvas: annotation.bounds).insetBy(dx: -3 / magnification, dy: -3 / magnification))
            context.setLineDash(phase: 0, lengths: [])
        }
        if selected.count == 1, let annotation = selected.first, !isDragging, annotation.id != editingID {
            for handle in annotation.handles {
                guard let position = annotation.position(of: handle) else { continue }
                let rect = HandleGeometry.handleRect(
                    center: geometry.viewPoint(fromCanvas: position),
                    diameter: EditorMetrics.handleDiameter,
                    magnification: magnification
                )
                let fill = handle == .control ? RGBAColor.annotationPink.cgColor : accent
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: rect)
                context.setFillColor(fill)
                let inset = EditorMetrics.handleBorderWidth / magnification
                context.fillEllipse(in: rect.insetBy(dx: inset, dy: inset))
            }
        }
        context.restoreGState()
    }

    // MARK: Invalidation

    private func invalidateCanvasRect(_ rect: CGRect, pad: CGFloat = 2) {
        guard !rect.isNull else { return }
        setNeedsDisplay(geometry.viewRect(fromCanvas: rect).insetBy(dx: -pad, dy: -pad))
    }

    private func chromeBounds(_ annotation: Annotation) -> CGRect {
        HandleGeometry.chromeBounds(
            of: annotation,
            pixelsPerScreenPoint: pixelsPerScreenPoint,
            handleDiameter: EditorMetrics.handleDiameter
        )
    }

    private func invalidateSelectionChrome() {
        let rect = model.store.selectedAnnotations.reduce(CGRect.null) { $0.union(chromeBounds($1)) }
        invalidateCanvasRect(rect)
    }

    /// Invalidates exactly what changed between `old` and the current state
    /// (painted bounds of changed annotations + selection chrome).
    private func stateDidChange(from old: EditorState) {
        let new = model.store.state
        textEditor?.annotationDidChange()
        if refreshGeometry() { return }
        if old.document.layers != new.document.layers || old.document.crop != new.document.crop
            || old.document.transform != new.document.transform || old.document.background != new.document.background {
            needsDisplay = true
            return
        }
        let painter = AnnotationPainter(canvasScale: new.document.canvas.scale)
        var dirty = CGRect.null
        if old.document.annotations != new.document.annotations {
            let oldByID = Dictionary(old.document.annotations.enumerated().map { ($1.id, ($0, $1)) }) { a, _ in a }
            let newByID = Dictionary(new.document.annotations.enumerated().map { ($1.id, ($0, $1)) }) { a, _ in a }
            for id in Set(oldByID.keys).union(newByID.keys) {
                let before = oldByID[id]
                let after = newByID[id]
                if before?.0 == after?.0, before?.1 == after?.1 { continue }
                for annotation in [before?.1, after?.1].compactMap({ $0 }) {
                    if annotation.isSpotlight {
                        needsDisplay = true
                        return
                    }
                    dirty = dirty.union(painter.paintedBounds(of: annotation)).union(chromeBounds(annotation))
                }
            }
        }
        if old.selection != new.selection {
            for annotation in old.document.annotations where old.selection.contains(annotation.id) {
                dirty = dirty.union(chromeBounds(annotation))
            }
            for annotation in new.document.annotations where new.selection.contains(annotation.id) {
                dirty = dirty.union(chromeBounds(annotation))
            }
        }
        invalidateCanvasRect(dirty)
    }
}

extension CanvasView {
    /// Recomputes what the view shows (plain canvas / crop mode / output with
    /// background). Returns whether anything changed (then all is redrawn and,
    /// if the size changed, the zoom refits).
    @discardableResult
    func refreshGeometry() -> Bool {
        let document = model.document
        let mode = CanvasDisplay.mode(for: document, cropping: model.isCropping)
        let new = CanvasDisplay.geometry(for: document, mode: mode) { model.renderer.outputLayout(of: document) }
        guard new != geometry || mode != display else { return false }
        let sizeChanged = new.viewSize != geometry.viewSize
        geometry = new
        display = mode
        drawnCropRect = nil
        setFrameSize(geometry.viewSize)
        needsDisplay = true
        if sizeChanged {
            let model = model
            Task { @MainActor in model.zoomHandler?(.fit) }
        }
        return true
    }

    /// Crop session opened / closed / edited.
    fileprivate func cropSessionDidChange() {
        if refreshGeometry() { return }
        guard let session = model.cropSession, let old = drawnCropRect else {
            needsDisplay = true
            return
        }
        // Only the band between the old and new rect changes (plus chrome).
        let new = geometry.viewRect(fromOutput: session.rect)
        let m = magnification
        setNeedsDisplay(CropOverlayPainter.chromeBounds(of: old, magnification: m).union(CropOverlayPainter.chromeBounds(of: new, magnification: m)))
    }
}

/// `NSMenuItem` that runs a closure.
nonisolated final class ActionMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() {
        let handler = handler
        MainActor.assumeIsolated { handler() }
    }
}
