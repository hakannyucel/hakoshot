import CoreGraphics

/// Freehand stroke smoothing for the pencil and highlighter ("auto-smoothing").
///
/// Pipeline (run once when the drag ends, result stored in `PathShape.points`):
/// 1. drop samples closer than `minDistance` to the previous kept sample
///    (mouse jitter),
/// 2. `iterations` passes of a 3-tap moving average (endpoints pinned),
/// 3. Ramer–Douglas–Peucker simplification with tolerance `epsilon`.
/// The renderer then draws a Catmull–Rom spline through the points
/// (`cubicSegments`), which adds the visual smoothness.
public enum PathSmoothing {
    public struct CubicSegment: Sendable, Hashable {
        public var start: CGPoint
        public var control1: CGPoint
        public var control2: CGPoint
        public var end: CGPoint
    }

    public static func smooth(
        _ points: [CGPoint],
        minDistance: Double = 2,
        iterations: Int = 2,
        epsilon: Double = 0.75
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = dedupe(points, minDistance: minDistance)
        for _ in 0..<max(iterations, 0) {
            result = movingAverage(result)
        }
        return simplify(result, epsilon: epsilon)
    }

    /// Uniform Catmull–Rom through `points`, as cubic Béziers (one per gap).
    /// Endpoints are duplicated as phantom neighbors. Fewer than 2 points → [].
    public static func cubicSegments(_ points: [CGPoint]) -> [CubicSegment] {
        guard points.count >= 2 else { return [] }
        var segments: [CubicSegment] = []
        segments.reserveCapacity(points.count - 1)
        for i in 0..<(points.count - 1) {
            let p0 = points[max(i - 1, 0)]
            let p1 = points[i]
            let p2 = points[i + 1]
            let p3 = points[min(i + 2, points.count - 1)]
            segments.append(CubicSegment(
                start: p1,
                control1: CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6),
                control2: CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6),
                end: p2
            ))
        }
        return segments
    }

    // MARK: Steps

    static func dedupe(_ points: [CGPoint], minDistance: Double) -> [CGPoint] {
        guard let first = points.first, let last = points.last else { return points }
        var kept = [first]
        for p in points.dropFirst().dropLast() {
            if let previous = kept.last, distance(previous, p) >= minDistance {
                kept.append(p)
            }
        }
        if let previous = kept.last, kept.count > 1, distance(previous, last) < minDistance {
            kept.removeLast()
        }
        kept.append(last)
        return kept
    }

    static func movingAverage(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var result = points
        for i in 1..<(points.count - 1) {
            let a = points[i - 1], b = points[i], c = points[i + 1]
            result[i] = CGPoint(x: (a.x + 2 * b.x + c.x) / 4, y: (a.y + 2 * b.y + c.y) / 4)
        }
        return result
    }

    /// Ramer–Douglas–Peucker, iterative.
    static func simplify(_ points: [CGPoint], epsilon: Double) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack: [(Int, Int)] = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            var maxDistance = 0.0
            var index = first
            for i in (first + 1)..<last {
                let d = HitTesting.distance(from: points[i], toSegment: points[first], points[last])
                if d > maxDistance {
                    maxDistance = d
                    index = i
                }
            }
            if maxDistance > epsilon {
                keep[index] = true
                stack.append((first, index))
                stack.append((index, last))
            }
        }
        return points.enumerated().compactMap { keep[$0.offset] ? $0.element : nil }
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
