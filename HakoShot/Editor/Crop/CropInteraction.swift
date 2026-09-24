import AppKit
import HakoKit

/// Mouse handling for crop mode. Points are display pixels (see `CropMath`).
/// Drag a handle to resize, inside the rect to move, outside to draw a new
/// rect. ⌘ held flips "Snap to edges" for the drag (report §9.4).
@MainActor
final class CropInteraction {
    private enum Drag {
        case resize(CropHandle, start: CGRect)
        case move(start: CGRect, origin: CGPoint)
        case create(anchor: CGPoint, start: CGRect)
    }

    private var drag: Drag?
    private var didMove = false

    var isDragging: Bool { drag != nil }

    /// - Parameter pixelsPerPoint: display pixels per screen point (tolerances).
    func mouseDown(at point: CGPoint, model: EditorViewModel, pixelsPerPoint: CGFloat) {
        guard let session = model.cropSession else { return }
        didMove = false
        let tolerance = EditorMetrics.cropHandleHitDistance * pixelsPerPoint
        if let handle = CropMath.handle(at: point, of: session.rect, tolerance: tolerance) {
            drag = .resize(handle, start: session.rect)
        } else if session.rect.contains(point) {
            drag = .move(start: session.rect, origin: point)
        } else {
            let anchor = CGPoint(x: min(max(point.x, session.bounds.minX), session.bounds.maxX),
                                 y: min(max(point.y, session.bounds.minY), session.bounds.maxY))
            drag = .create(anchor: anchor, start: session.rect)
        }
    }

    func mouseDragged(to point: CGPoint, event: NSEvent, model: EditorViewModel, pixelsPerPoint: CGFloat) {
        guard let drag, var session = model.cropSession else { return }
        didMove = true
        let snaps = session.snapping != event.modifierFlags.contains(.command)
        let targets = snaps ? session.targets : .none
        let tolerance = snaps ? EditorMetrics.cropSnapDistance * pixelsPerPoint : 0
        switch drag {
        case .resize(let handle, let start):
            session.rect = CropMath.resize(start, handle: handle, to: point, ratio: session.ratio,
                                           bounds: session.bounds, snap: targets, tolerance: tolerance)
        case .move(let start, let origin):
            session.rect = CropMath.move(start, by: CGVector(dx: point.x - origin.x, dy: point.y - origin.y),
                                         bounds: session.bounds, snap: targets, tolerance: tolerance)
        case .create(let anchor, _):
            let seed = CGRect(origin: anchor, size: .zero)
            session.rect = CropMath.resize(seed, handle: .corner(from: anchor, to: point), to: point, ratio: session.ratio,
                                           bounds: session.bounds, snap: targets, tolerance: tolerance)
        }
        model.cropSession = session
    }

    func mouseUp(model: EditorViewModel) {
        // A click outside without dragging keeps the old rect.
        if case .create(_, let start)? = drag, !didMove { model.updateCrop { $0.rect = start } }
        drag = nil
    }

    /// Esc mid-drag: restore the rect from before it.
    func cancel(model: EditorViewModel) -> Bool {
        guard let drag else { return false }
        let start: CGRect = switch drag {
        case .resize(_, let s), .move(let s, _), .create(_, let s): s
        }
        model.updateCrop { $0.rect = start }
        self.drag = nil
        return true
    }

    func cursor(at point: CGPoint, session: CropSession, pixelsPerPoint: CGFloat) -> NSCursor {
        let tolerance = EditorMetrics.cropHandleHitDistance * pixelsPerPoint
        if let handle = CropMath.handle(at: point, of: session.rect, tolerance: tolerance) {
            let position: NSCursor.FrameResizePosition = switch handle {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        return session.rect.contains(point) ? .openHand : .crosshair
    }
}

/// Draws crop mode's chrome in view points (report §9.4): dim outside the
/// rect, thin white border, rule-of-thirds lines, white square handles.
enum CropOverlayPainter {
    static func draw(rect: CGRect, imageRect: CGRect, magnification: CGFloat, context: CGContext) {
        let m = max(magnification, 0.0001)
        context.saveGState()
        defer { context.restoreGState() }

        // Dim outside.
        context.setFillColor(Tokens.Palette.cropDim.cgColor)
        context.addRect(imageRect)
        context.addRect(rect)
        context.fillPath(using: .evenOdd)

        // Rule of thirds.
        context.setStrokeColor(NSColor.white.withAlphaComponent(EditorMetrics.cropGuideOpacity).cgColor)
        context.setLineWidth(1 / m)
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            let y = rect.minY + rect.height * CGFloat(i) / 3
            context.move(to: CGPoint(x: x, y: rect.minY))
            context.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.move(to: CGPoint(x: rect.minX, y: y))
            context.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        context.strokePath()

        // Border.
        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(EditorMetrics.cropBorderWidth / m)
        context.stroke(rect)

        // Handles: small white squares with a hairline shadow.
        let side = EditorMetrics.cropHandleSize / m
        context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        for handle in CropHandle.allCases {
            let p = handle.position(in: rect)
            context.fill(CGRect(x: p.x - side / 2, y: p.y - side / 2, width: side, height: side))
        }
    }

    /// View area a rect's chrome covers (for invalidation).
    static func chromeBounds(of rect: CGRect, magnification: CGFloat) -> CGRect {
        let pad = (EditorMetrics.cropHandleSize + 6) / max(magnification, 0.0001)
        return rect.insetBy(dx: -pad, dy: -pad)
    }
}
