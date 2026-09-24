import AppKit
import HakoKit

/// What tool controllers need from the canvas.
@MainActor
protocol CanvasToolHost: AnyObject {
    var model: EditorViewModel { get }
    /// Canvas pixels per screen point at the current zoom (`HitTesting` tolerance input).
    var pixelsPerScreenPoint: CGFloat { get }
    /// Marquee rectangle in canvas pixels (`nil` hides it).
    var marqueeRect: CGRect? { get set }
    /// Hides selection handles while a drag is in progress.
    var isDragging: Bool { get set }
    func beginTextEditing(_ id: Annotation.ID, isNew: Bool)
}

/// One controller per tool family: `SelectionTool` (move / transform),
/// `CreationTool` (shapes, lines, arrows, freehand, counter, redaction,
/// spotlight) and `TextTool`. Points are canvas pixels.
@MainActor
protocol CanvasTool: AnyObject {
    func mouseDown(at point: CGPoint, event: NSEvent, host: CanvasToolHost)
    func mouseDragged(to point: CGPoint, event: NSEvent, host: CanvasToolHost)
    func mouseUp(at point: CGPoint, event: NSEvent, host: CanvasToolHost)
    /// Esc during a drag: revert it. Returns whether a drag was cancelled.
    func cancel(host: CanvasToolHost) -> Bool
    func cursor(at point: CGPoint, host: CanvasToolHost) -> NSCursor
}

extension NSEvent {
    var isShiftDown: Bool { modifierFlags.contains(.shift) }
    var isOptionDown: Bool { modifierFlags.contains(.option) }
}

extension HandleGeometry {
    @MainActor
    static func cursor(for handle: AnnotationHandle) -> NSCursor {
        switch cursorKind(for: handle) {
        case .frame(let position): NSCursor.frameResize(position: position, directions: .all)
        case .point: NSCursor.crosshair
        }
    }
}
