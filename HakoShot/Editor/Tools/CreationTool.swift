import AppKit
import HakoKit

/// Drag-to-create tools: rectangle, filled rectangle, ellipse, line, arrow,
/// pencil, highlighter, counter (click), redaction, spotlight. Uses
/// `AnnotationFactory` begin/update/finish inside one store interaction, so a
/// creation is one undo step and a too-small drag leaves nothing behind.
/// Clicking the current selection moves / resizes it instead (`SelectionTool`).
final class CreationTool: CanvasTool {
    let tool: AnnotationTool
    private let transformer = SelectionTool(allowsMarquee: false)
    private var transforming = false
    private var creation: (id: Annotation.ID, anchor: CGPoint)?

    init(tool: AnnotationTool) {
        self.tool = tool
    }

    /// Freehand strokes stay unselected so the next stroke can start anywhere.
    private var selectsResult: Bool {
        tool != .pencil && tool != .highlighter
    }

    func mouseDown(at point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        if transformer.beginTransform(at: point, event: event, host: host) {
            transforming = true
            return
        }
        let model = host.model
        let name = "Add \(Self.displayName(tool))"
        guard let annotation = AnnotationFactory.begin(
            tool: tool,
            at: point,
            settings: model.store.toolSettings,
            scale: Double(model.canvasScale),
            nextCounterNumber: model.store.nextCounterNumber
        ) else { return }
        model.beginInteraction(name)
        model.perform(.add(annotation, select: selectsResult))
        if !selectsResult { model.perform(.clearSelection) }
        creation = (annotation.id, point)
        host.isDragging = true
    }

    func mouseDragged(to point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        if transforming {
            transformer.mouseDragged(to: point, event: event, host: host)
            return
        }
        guard let creation, let current = host.model.document.annotation(withID: creation.id) else { return }
        let updated = AnnotationFactory.update(current, anchor: creation.anchor, to: point, constrained: event.isShiftDown)
        host.model.perform(.update(updated))
    }

    func mouseUp(at point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        if transforming {
            transformer.mouseUp(at: point, event: event, host: host)
            transforming = false
            return
        }
        defer {
            creation = nil
            host.isDragging = false
        }
        let model = host.model
        guard let creation, let current = model.document.annotation(withID: creation.id) else {
            model.cancelInteraction()
            return
        }
        if let finished = AnnotationFactory.finish(current) {
            model.perform(.update(finished))
            model.endInteraction()
        } else {
            model.cancelInteraction()
        }
    }

    func cancel(host: CanvasToolHost) -> Bool {
        if transforming {
            transforming = false
            return transformer.cancel(host: host)
        }
        guard creation != nil else { return false }
        creation = nil
        host.isDragging = false
        host.model.cancelInteraction()
        return true
    }

    func cursor(at point: CGPoint, host: CanvasToolHost) -> NSCursor {
        if let handleCursor = SelectionTool.handleCursor(at: point, host: host) { return handleCursor }
        return .crosshair
    }

    static func displayName(_ tool: AnnotationTool) -> String {
        EditorToolDescriptor.descriptor(for: tool).title
    }
}

/// Text tool: click empty canvas to add a text box and type; click a text box
/// to edit it (drag it to move it).
final class TextTool: CanvasTool {
    private let transformer = SelectionTool(allowsMarquee: false)
    private var transforming = false
    private var pressedText: Annotation.ID?

    func mouseDown(at point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        let model = host.model
        pressedText = nil
        if let hit = HitTesting.topmostAnnotation(at: point, in: model.document.annotations, pixelsPerPoint: host.pixelsPerScreenPoint),
           model.document.annotation(withID: hit)?.kind.tag == .text {
            // Select (and allow moving) first; a click without a drag edits.
            if !model.selection.contains(hit) { model.perform(.select([hit])) }
            pressedText = hit
        }
        if transformer.beginTransform(at: point, event: event, host: host) {
            transforming = true
            return
        }
        guard pressedText == nil else { return }
        createText(at: point, host: host)
    }

    func mouseDragged(to point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        guard transforming else { return }
        transformer.mouseDragged(to: point, event: event, host: host)
    }

    func mouseUp(at point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        guard transforming else { return }
        transformer.mouseUp(at: point, event: event, host: host)
        transforming = false
        if !transformer.didDrag, let pressedText {
            host.beginTextEditing(pressedText, isNew: false)
        }
    }

    func cancel(host: CanvasToolHost) -> Bool {
        guard transforming else { return false }
        transforming = false
        return transformer.cancel(host: host)
    }

    func cursor(at point: CGPoint, host: CanvasToolHost) -> NSCursor {
        if let handleCursor = SelectionTool.handleCursor(at: point, host: host) { return handleCursor }
        return .iBeam
    }

    private func createText(at point: CGPoint, host: CanvasToolHost) {
        let model = host.model
        guard var annotation = AnnotationFactory.begin(
            tool: .text,
            at: point,
            settings: model.store.toolSettings,
            scale: Double(model.canvasScale),
            nextCounterNumber: model.store.nextCounterNumber
        ), case .text(var shape) = annotation.kind else { return }
        // Center the first line on the click, like a caret placed there.
        let lineHeight = TextLayout(shape: shape).lineHeight
        shape.frame.origin.y = point.y - lineHeight / 2
        shape = model.fitted(shape, autoWidth: true)
        annotation.kind = .text(shape)
        model.beginInteraction("Add Text")
        model.perform(.add(annotation))
        host.beginTextEditing(annotation.id, isNew: true)
    }
}
