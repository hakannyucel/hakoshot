import CoreGraphics
import Foundation

/// Paths for the four arrow styles (spec: `ArrowStyle` doc comments).
enum ArrowGeometry {
    struct Parts {
        /// Shaft to stroke with width `w` and round caps (`nil` for `.thick`).
        var shaft: CGPath?
        /// Filled head(s), or the whole body for `.thick`.
        var fill: CGPath
    }

    static func parts(for shape: ArrowShape, strokeWidth w: Double) -> Parts {
        switch shape.arrowStyle {
        case .standard: straight(shape, w: w, doubleHeaded: false)
        case .doubleHeaded: straight(shape, w: w, doubleHeaded: true)
        case .curved: curved(shape, w: w)
        case .thick: thick(shape, w: w)
        }
    }

    // MARK: Styles

    private static func straight(_ s: ArrowShape, w: Double, doubleHeaded: Bool) -> Parts {
        let length = distance(s.start, s.end)
        guard length > 0.001 else { return dot(at: s.end, w: w) }
        let u = unit(from: s.start, to: s.end)
        let (headLength, halfWidth) = headSize(w: w, available: doubleHeaded ? length / 2 : length)
        let fill = CGMutablePath()
        let endBase = s.end - u * headLength
        addHead(to: fill, tip: s.end, base: endBase, u: u, halfWidth: halfWidth)
        var tail = s.start
        if doubleHeaded {
            let startBase = s.start + u * headLength
            addHead(to: fill, tip: s.start, base: startBase, u: u * -1, halfWidth: halfWidth)
            tail = startBase
        }
        let shaft = CGMutablePath()
        shaft.move(to: tail)
        shaft.addLine(to: endBase)
        return Parts(shaft: shaft, fill: fill)
    }

    private static func curved(_ s: ArrowShape, w: Double) -> Parts {
        guard let c = s.resolvedControl else { return straight(s, w: w, doubleHeaded: false) }
        let chord = distance(s.start, s.end)
        guard chord > 0.001 else { return dot(at: s.end, w: w) }
        var tangent = s.end - c
        if hypot(tangent.x, tangent.y) < 0.001 { tangent = s.end - s.start }
        let u = normalized(tangent)
        let (headLength, halfWidth) = headSize(w: w, available: chord)
        let fill = CGMutablePath()
        let base = s.end - u * headLength
        addHead(to: fill, tip: s.end, base: base, u: u, halfWidth: halfWidth)

        // Trim the curve where it enters the head (slightly inside the base so
        // the round cap hides the seam), via bisection on distance to the tip.
        let target = headLength * 0.85
        var lo = 0.0
        var hi = 1.0
        for _ in 0..<32 {
            let mid = (lo + hi) / 2
            if distance(quadPoint(s.start, c, s.end, t: mid), s.end) > target { lo = mid } else { hi = mid }
        }
        let t = lo
        // de Casteljau: the sub-curve on [0, t].
        let control = s.start + (c - s.start) * t
        let endPoint = quadPoint(s.start, c, s.end, t: t)
        let shaft = CGMutablePath()
        shaft.move(to: s.start)
        shaft.addQuadCurve(to: endPoint, control: control)
        return Parts(shaft: shaft, fill: fill)
    }

    private static func thick(_ s: ArrowShape, w: Double) -> Parts {
        let length = distance(s.start, s.end)
        guard length > 0.001 else { return dot(at: s.end, w: w) }
        let u = unit(from: s.start, to: s.end)
        let n = CGPoint(x: -u.y, y: u.x)
        let (headLength, halfWidth) = headSize(w: w, available: length)
        let base = s.end - u * headLength
        let tailHalf = 0.25 * w
        let baseHalf = min(w, halfWidth * 0.5)
        let path = CGMutablePath()
        path.move(to: s.start + n * tailHalf)
        path.addLine(to: base + n * baseHalf)
        path.addLine(to: base + n * halfWidth)
        path.addLine(to: s.end)
        path.addLine(to: base - n * halfWidth)
        path.addLine(to: base - n * baseHalf)
        path.addLine(to: s.start - n * tailHalf)
        path.closeSubpath()
        path.addEllipse(in: CGRect(x: s.start.x - tailHalf, y: s.start.y - tailHalf, width: 2 * tailHalf, height: 2 * tailHalf))
        return Parts(shaft: nil, fill: path)
    }

    // MARK: Helpers

    /// Head length / half-width, shrunk proportionally when the arrow is
    /// shorter than a full head.
    private static func headSize(w: Double, available: Double) -> (Double, Double) {
        let length = ArrowShape.headLength(strokeWidth: w)
        let half = ArrowShape.headHalfWidth(strokeWidth: w)
        guard available < length else { return (length, half) }
        let k = max(available, 0) / length
        return (length * k, half * k)
    }

    private static func addHead(to path: CGMutablePath, tip: CGPoint, base: CGPoint, u: CGPoint, halfWidth: Double) {
        let n = CGPoint(x: -u.y, y: u.x)
        path.move(to: tip)
        path.addLine(to: base + n * halfWidth)
        path.addLine(to: base - n * halfWidth)
        path.closeSubpath()
    }

    private static func dot(at point: CGPoint, w: Double) -> Parts {
        let path = CGPath(ellipseIn: CGRect(x: point.x - w / 2, y: point.y - w / 2, width: w, height: w), transform: nil)
        return Parts(shaft: nil, fill: path)
    }

    static func quadPoint(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, t: Double) -> CGPoint {
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * p0.x + 2 * mt * t * p1.x + t * t * p2.x,
            y: mt * mt * p0.y + 2 * mt * t * p1.y + t * t * p2.y
        )
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func unit(from a: CGPoint, to b: CGPoint) -> CGPoint { normalized(b - a) }

    private static func normalized(_ v: CGPoint) -> CGPoint {
        let len = hypot(v.x, v.y)
        return len > 0 ? CGPoint(x: v.x / len, y: v.y / len) : CGPoint(x: 1, y: 0)
    }
}

private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func * (a: CGPoint, k: Double) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }
