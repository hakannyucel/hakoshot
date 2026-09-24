import CoreGraphics
import Foundation

/// Pure hit-testing for annotations (plan §4.10). All inputs are in image pixel
/// space. `pixelsPerPoint` converts on-screen point tolerances into pixels:
/// pass `canvas.scale / zoom` (e.g. 2× capture shown at 50 % → 4), so
/// tolerances feel the same at every zoom level.
public enum HitTesting {
    /// Minimum hit slop around strokes, in screen points.
    public static let minimumTolerancePoints = 4.0
    /// Hit radius of a resize handle, in screen points (handles are drawn ~8 pt).
    public static let handleRadiusPoints = 6.0

    /// Stroke-aware slop: `max(strokeWidth / 2, 4 pt)` in pixels.
    public static func tolerance(for annotation: Annotation, pixelsPerPoint: Double) -> Double {
        max(annotation.style.strokeWidth / 2, minimumTolerancePoints * pixelsPerPoint)
    }

    /// Topmost annotation under `point` (last in z-order wins), or `nil`.
    public static func topmostAnnotation(
        at point: CGPoint,
        in annotations: [Annotation],
        pixelsPerPoint: Double = 1
    ) -> Annotation.ID? {
        annotations.last { hits(point, annotation: $0, pixelsPerPoint: pixelsPerPoint) }?.id
    }

    /// Whether `point` is on `annotation`.
    ///
    /// - Outline rectangle / ellipse: only near the stroke (inside counts too
    ///   when `style.fill` is set), so you can click through a hollow frame.
    /// - Line, arrow, pencil, highlighter: distance to the (sampled) path.
    ///   Arrows also hit on their head(s).
    /// - Filled shapes, text, redaction, spotlight, image: anywhere inside the
    ///   bounds grown by the tolerance.
    /// - Counter: inside the badge circle plus tolerance.
    public static func hits(_ point: CGPoint, annotation: Annotation, pixelsPerPoint: Double = 1) -> Bool {
        let tol = tolerance(for: annotation, pixelsPerPoint: pixelsPerPoint)
        switch annotation.kind {
        case .rectangle(let s):
            if annotation.style.fill != nil, s.rect.insetBy(dx: -tol, dy: -tol).contains(point) { return true }
            return distance(from: point, toRectBorder: s.rect) <= tol
        case .ellipse(let s):
            if annotation.style.fill != nil, isInsideEllipse(point, in: s.rect.insetBy(dx: -tol, dy: -tol)) {
                return true
            }
            return distance(from: point, toPolyline: ellipsePolygon(s.rect), closed: true) <= tol
        case .filledRectangle(let s):
            return s.rect.insetBy(dx: -tol, dy: -tol).contains(point)
        case .line(let s):
            return distance(from: point, toSegment: s.start, s.end) <= tol
        case .arrow(let s):
            let w = annotation.style.strokeWidth
            let bodyTol = s.arrowStyle == .thick ? max(tol, w) : tol
            if distance(from: point, toPolyline: s.polyline(), closed: false) <= bodyTol { return true }
            let head = ArrowShape.headLength(strokeWidth: w)
            if hypot(point.x - s.end.x, point.y - s.end.y) <= head { return true }
            if s.arrowStyle == .doubleHeaded, hypot(point.x - s.start.x, point.y - s.start.y) <= head { return true }
            return false
        case .pencil(let s), .highlighter(let s):
            return distance(from: point, toPolyline: s.points, closed: false) <= tol
        case .counter(let s):
            return hypot(point.x - s.center.x, point.y - s.center.y) <= s.diameter / 2 + tol
        case .text, .redaction, .spotlight, .image:
            let slop = minimumTolerancePoints * pixelsPerPoint
            return annotation.bounds.insetBy(dx: -slop, dy: -slop).contains(point)
        }
    }

    /// The handle of `annotation` under `point`, if any. Check this on the
    /// selected annotation **before** `topmostAnnotation` so handles win.
    public static func handle(
        at point: CGPoint,
        of annotation: Annotation,
        pixelsPerPoint: Double = 1
    ) -> AnnotationHandle? {
        let radius = handleRadiusPoints * pixelsPerPoint
        var best: (AnnotationHandle, CGFloat)?
        for handle in annotation.handles {
            guard let position = annotation.position(of: handle) else { continue }
            let d = hypot(point.x - position.x, point.y - position.y)
            if d <= radius, d < (best?.1 ?? .infinity) {
                best = (handle, d)
            }
        }
        return best?.0
    }

    /// IDs (in z-order) whose visual bounds intersect `rect` — marquee selection.
    public static func annotations(intersecting rect: CGRect, in annotations: [Annotation]) -> [Annotation.ID] {
        let r = rect.standardized
        return annotations.filter { $0.visualBounds.intersects(r) }.map(\.id)
    }

    // MARK: - Geometry primitives

    public static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared, 0), 1)
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    public static func distance(from p: CGPoint, toPolyline points: [CGPoint], closed: Bool) -> Double {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(p.x - first.x, p.y - first.y) }
        var best = Double.infinity
        for i in 0..<(points.count - 1) {
            best = min(best, distance(from: p, toSegment: points[i], points[i + 1]))
        }
        if closed, let last = points.last {
            best = min(best, distance(from: p, toSegment: last, first))
        }
        return best
    }

    /// Distance to the rectangle's outline (0 on the edge, positive inside and outside).
    public static func distance(from p: CGPoint, toRectBorder r: CGRect) -> Double {
        if r.contains(p) {
            return min(p.x - r.minX, r.maxX - p.x, p.y - r.minY, r.maxY - p.y)
        }
        let dx = max(r.minX - p.x, 0, p.x - r.maxX)
        let dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return hypot(dx, dy)
    }

    static func isInsideEllipse(_ p: CGPoint, in r: CGRect) -> Bool {
        let rx = r.width / 2, ry = r.height / 2
        guard rx > 0, ry > 0 else { return false }
        let nx = (p.x - r.midX) / rx
        let ny = (p.y - r.midY) / ry
        return nx * nx + ny * ny <= 1
    }

    static func ellipsePolygon(_ r: CGRect, samples: Int = 72) -> [CGPoint] {
        (0..<samples).map { i in
            let angle = Double(i) / Double(samples) * 2 * .pi
            return CGPoint(x: r.midX + r.width / 2 * cos(angle), y: r.midY + r.height / 2 * sin(angle))
        }
    }
}
