import AppKit
import CoreGraphics
import HakoKit

/// Pure geometry for selection chrome and drags (tested).
nonisolated enum HandleGeometry {
    /// Visual rect of a handle centered on `center` (view points) that appears
    /// `diameter` screen points wide at `magnification`.
    static func handleRect(center: CGPoint, diameter: CGFloat, magnification: CGFloat) -> CGRect {
        let size = diameter / max(magnification, 0.0001)
        return CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
    }

    /// Canvas-pixel rect covering everything the selection chrome of `annotation`
    /// can draw (outline + handles), for invalidation.
    static func chromeBounds(of annotation: Annotation, pixelsPerScreenPoint: CGFloat, handleDiameter: CGFloat) -> CGRect {
        var rect = annotation.bounds.union(annotation.visualBounds)
        for handle in annotation.handles {
            if let p = annotation.position(of: handle) {
                rect = rect.union(CGRect(origin: p, size: .zero))
            }
        }
        let pad = (handleDiameter / 2 + 3) * pixelsPerScreenPoint
        return rect.insetBy(dx: -pad, dy: -pad)
    }

    /// Whether the selection outline is a box (false for lines / arrows, which
    /// only show their endpoint handles).
    static func drawsOutline(for annotation: Annotation) -> Bool {
        switch annotation.kind {
        case .line, .arrow: false
        default: true
        }
    }

    /// Move delta; with `constrained` (⇧) locked to the dominant axis.
    static func constrainedDelta(_ delta: CGVector, constrained: Bool) -> CGVector {
        guard constrained else { return delta }
        return abs(delta.dx) >= abs(delta.dy) ? CGVector(dx: delta.dx, dy: 0) : CGVector(dx: 0, dy: delta.dy)
    }

    /// Where a dragged endpoint handle goes; with ⇧ the segment from the other
    /// endpoint snaps to 45°.
    static func endpointTarget(_ point: CGPoint, handle: AnnotationHandle, of annotation: Annotation, constrained: Bool) -> CGPoint {
        guard constrained else { return point }
        let other: AnnotationHandle?
        switch handle {
        case .start: other = .end
        case .end: other = .start
        default: other = nil
        }
        guard let other, let anchor = annotation.position(of: other) else { return point }
        return AnnotationFactory.snapAngle(from: anchor, to: point)
    }

    /// Resize-cursor direction for a handle.
    enum CursorKind: Equatable {
        case frame(NSCursor.FrameResizePosition)
        case point
    }

    static func cursorKind(for handle: AnnotationHandle) -> CursorKind {
        switch handle {
        case .topLeft: .frame(.topLeft)
        case .top: .frame(.top)
        case .topRight: .frame(.topRight)
        case .right: .frame(.right)
        case .bottomRight: .frame(.bottomRight)
        case .bottom: .frame(.bottom)
        case .bottomLeft: .frame(.bottomLeft)
        case .left: .frame(.left)
        case .start, .end, .control: .point
        }
    }
}
