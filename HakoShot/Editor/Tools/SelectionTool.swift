import AppKit
import HakoKit

/// Move tool: click to select (⇧ toggles), drag to move (⇧ locks the axis,
/// ⌥ duplicates first), drag a handle to resize (⇧ keeps aspect — frees it for images — / snaps line
/// ends to 45°), drag on empty canvas for a marquee. Double-click text to edit.
///
/// Creation tools reuse it with `allowsMarquee = false` to transform what's
/// already selected (`beginTransform`).
final class SelectionTool: CanvasTool {
    private enum Mode {
        case idle
        case move(start: CGPoint, applied: CGVector, began: Bool)
        case resize(id: Annotation.ID, handle: AnnotationHandle, began: Bool)
        case marquee(start: CGPoint, base: Set<Annotation.ID>)
    }

    let allowsMarquee: Bool
    private var mode: Mode = .idle
    /// Annotation under the last mouse-down (for text click-to-edit).
    private(set) var pressedAnnotation: Annotation.ID?
    private(set) var didDrag = false

    init(allowsMarquee: Bool) {
        self.allowsMarquee = allowsMarquee
    }

    var isActive: Bool {
        if case .idle = mode { return false }
        return true
    }

    /// Starts a resize / move if `point` is on a handle of the single selection,
    /// or on an annotation the tool may move (any for Move, only selected ones
    /// for creation tools). Returns whether it took the click.
    @discardableResult
    func beginTransform(at point: CGPoint, event: NSEvent, host: CanvasToolHost) -> Bool {
        let model = host.model
        let ppp = host.pixelsPerScreenPoint
        didDrag = false
        pressedAnnotation = nil
        if model.selection.count == 1, let selected = model.store.selectedAnnotations.first,
           let handle = HitTesting.handle(at: point, of: selected, pixelsPerPoint: ppp) {
            mode = .resize(id: selected.id, handle: handle, began: false)
            pressedAnnotation = selected.id
            return true
        }
        guard let hit = HitTesting.topmostAnnotation(at: point, in: model.document.annotations, pixelsPerPoint: ppp),
              allowsMarquee || model.selection.contains(hit)
        else { return false }
        pressedAnnotation = hit
        if allowsMarquee, event.isShiftDown {
            model.perform(.toggleSelection(hit))
            guard model.selection.contains(hit) else {
                mode = .idle
                return true
            }
        } else if !model.selection.contains(hit) {
            model.perform(.select([hit]))
        }
        mode = .move(start: point, applied: .zero, began: false)
        return true
    }

    func mouseDown(at point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        if event.clickCount == 2,
           let hit = HitTesting.topmostAnnotation(at: point, in: host.model.document.annotations, pixelsPerPoint: host.pixelsPerScreenPoint),
           host.model.document.annotation(withID: hit)?.kind.tag == .text {
            mode = .idle
            host.beginTextEditing(hit, isNew: false)
            return
        }
        if beginTransform(at: point, event: event, host: host) { return }
        guard allowsMarquee else { return }
        let base = event.isShiftDown ? host.model.selection : []
        if !event.isShiftDown { host.model.clearSelection() }
        mode = .marquee(start: point, base: base)
    }

    func mouseDragged(to point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        let model = host.model
        switch mode {
        case .idle:
            return
        case .move(let start, let applied, var began):
            didDrag = true
            if !began {
                began = true
                host.isDragging = true
                if event.isOptionDown {
                    model.beginInteraction("Duplicate")
                    model.perform(.duplicate(model.selection, offset: .zero))
                } else {
                    model.beginInteraction("Move")
                }
            }
            let total = HandleGeometry.constrainedDelta(
                CGVector(dx: point.x - start.x, dy: point.y - start.y),
                constrained: event.isShiftDown
            )
            let delta = CGVector(dx: total.dx - applied.dx, dy: total.dy - applied.dy)
            if delta != .zero { model.perform(.move(model.selection, by: delta)) }
            mode = .move(start: start, applied: total, began: began)
        case .resize(let id, let handle, var began):
            didDrag = true
            guard let annotation = model.document.annotation(withID: id) else { return }
            if !began {
                began = true
                host.isDragging = true
                model.beginInteraction("Resize")
                mode = .resize(id: id, handle: handle, began: true)
            }
            let target = HandleGeometry.endpointTarget(point, handle: handle, of: annotation, constrained: event.isShiftDown)
            // Images keep their aspect ratio unless ⇧ is held; other shapes the reverse.
            let keepAspect = annotation.kind.tag == .image ? !event.isShiftDown : event.isShiftDown
            model.perform(.resize(id, handle: handle, to: target, keepAspect: keepAspect))
            if let resized = model.document.annotation(withID: id), case .text = resized.kind {
                model.perform(.update(model.textRefitted(resized)))
            }
        case .marquee(let start, let base):
            didDrag = true
            let rect = CGRect(x: start.x, y: start.y, width: point.x - start.x, height: point.y - start.y).standardized
            host.marqueeRect = rect
            let hits = HitTesting.annotations(intersecting: rect, in: model.document.annotations)
            let newSelection = base.union(hits)
            if newSelection != model.selection { model.perform(.select(newSelection)) }
        }
    }

    func mouseUp(at point: CGPoint, event: NSEvent, host: CanvasToolHost) {
        switch mode {
        case .move(_, _, let began), .resize(_, _, let began):
            if began { host.model.endInteraction() }
        case .marquee:
            host.marqueeRect = nil
        case .idle:
            break
        }
        host.isDragging = false
        mode = .idle
    }

    func cancel(host: CanvasToolHost) -> Bool {
        defer {
            mode = .idle
            host.isDragging = false
            host.marqueeRect = nil
        }
        switch mode {
        case .move(_, _, let began), .resize(_, _, let began):
            if began { host.model.cancelInteraction() }
            return true
        case .marquee:
            return true
        case .idle:
            return false
        }
    }

    func cursor(at point: CGPoint, host: CanvasToolHost) -> NSCursor {
        if let handleCursor = Self.handleCursor(at: point, host: host) { return handleCursor }
        return .arrow
    }

    /// Resize cursor when hovering a handle of the single selection.
    static func handleCursor(at point: CGPoint, host: CanvasToolHost) -> NSCursor? {
        let model = host.model
        guard model.selection.count == 1, let selected = model.store.selectedAnnotations.first,
              let handle = HitTesting.handle(at: point, of: selected, pixelsPerPoint: host.pixelsPerScreenPoint)
        else { return nil }
        return HandleGeometry.cursor(for: handle)
    }
}
