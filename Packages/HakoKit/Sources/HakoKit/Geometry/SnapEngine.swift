import CoreGraphics

/// Edge snapping for the selection overlay (plan §5.4): while a selection edge
/// is dragged it jumps to a nearby window or display edge when it is within
/// `threshold` points. All values are Quartz global points.
///
/// Built once per overlay session from the window list and display frames;
/// every query is a linear scan over a few dozen edges (cheap at 120 Hz).
/// Window edges only attract when the moving edge overlaps them on the other
/// axis (a window's left edge does not pull a point far above the window);
/// display edges always attract.
public struct SnapEngine: Sendable, Equatable {
    /// Plan §5.4: 6 pt.
    public static let defaultThreshold: CGFloat = 6

    /// A vertical (`x` = const) or horizontal (`y` = const) edge segment.
    public struct Edge: Sendable, Equatable, Hashable {
        /// `x` for a vertical edge, `y` for a horizontal edge.
        public var position: CGFloat
        /// Extent on the other axis; `nil` = infinite (display edges).
        public var span: ClosedRange<CGFloat>?

        public init(position: CGFloat, span: ClosedRange<CGFloat>?) {
            self.position = position
            self.span = span
        }
    }

    public var threshold: CGFloat
    /// Edges with a constant `x`.
    public private(set) var verticalEdges: [Edge]
    /// Edges with a constant `y`.
    public private(set) var horizontalEdges: [Edge]

    public init(windowFrames: [GlobalRect], displayFrames: [GlobalRect], threshold: CGFloat = SnapEngine.defaultThreshold) {
        self.threshold = threshold
        var vertical: [Edge] = []
        var horizontal: [Edge] = []
        for frame in windowFrames where frame.width > 0 && frame.height > 0 {
            let ys = frame.minY...frame.maxY
            let xs = frame.minX...frame.maxX
            vertical.append(Edge(position: frame.minX, span: ys))
            vertical.append(Edge(position: frame.maxX, span: ys))
            horizontal.append(Edge(position: frame.minY, span: xs))
            horizontal.append(Edge(position: frame.maxY, span: xs))
        }
        for frame in displayFrames {
            vertical.append(Edge(position: frame.minX, span: nil))
            vertical.append(Edge(position: frame.maxX, span: nil))
            horizontal.append(Edge(position: frame.minY, span: nil))
            horizontal.append(Edge(position: frame.maxY, span: nil))
        }
        verticalEdges = vertical
        horizontalEdges = horizontal
    }

    /// An engine that never snaps.
    public static let disabled = SnapEngine(windowFrames: [], displayFrames: [], threshold: 0)

    // MARK: Queries

    /// `x` moved to the nearest vertical edge within `threshold` whose span
    /// overlaps `span` (the moving edge's extent in y), else `x` unchanged.
    public func snapX(_ x: CGFloat, spanning span: ClosedRange<CGFloat>) -> CGFloat {
        Self.nearest(to: x, in: verticalEdges, overlapping: span, threshold: threshold) ?? x
    }

    /// `y` moved to the nearest horizontal edge within `threshold` whose span
    /// overlaps `span` (the moving edge's extent in x), else `y` unchanged.
    public func snapY(_ y: CGFloat, spanning span: ClosedRange<CGFloat>) -> CGFloat {
        Self.nearest(to: y, in: horizontalEdges, overlapping: span, threshold: threshold) ?? y
    }

    /// A dragged corner (e.g. the pointer while drawing a selection).
    public func snap(_ point: CGPoint) -> CGPoint {
        CGPoint(x: snapX(point.x, spanning: point.y...point.y), y: snapY(point.y, spanning: point.x...point.x))
    }

    /// Snaps the edges listed in `edges` of `rect` independently (resize with
    /// a handle). Edges that are not moving stay put.
    public func snapEdges(_ edges: RectEdges, of rect: GlobalRect) -> GlobalRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        let ys = rect.minY...rect.maxY
        let xs = rect.minX...rect.maxX
        if edges.contains(.minX) { minX = snapX(minX, spanning: ys) }
        if edges.contains(.maxX) { maxX = snapX(maxX, spanning: ys) }
        if edges.contains(.minY) { minY = snapY(minY, spanning: xs) }
        if edges.contains(.maxY) { maxY = snapY(maxY, spanning: xs) }
        guard maxX > minX, maxY > minY else { return rect }
        return GlobalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Moves `rect` (size unchanged) so its closest edge on each axis lands on
    /// a nearby edge (moving a selection). Per axis the smaller correction of
    /// the two edges wins.
    public func snapTranslation(of rect: GlobalRect) -> GlobalRect {
        let ys = rect.minY...rect.maxY
        let xs = rect.minX...rect.maxX
        let dx = Self.smallerCorrection(
            snapX(rect.minX, spanning: ys) - rect.minX,
            snapX(rect.maxX, spanning: ys) - rect.maxX
        )
        let dy = Self.smallerCorrection(
            snapY(rect.minY, spanning: xs) - rect.minY,
            snapY(rect.maxY, spanning: xs) - rect.maxY
        )
        return GlobalRect(x: rect.minX + dx, y: rect.minY + dy, width: rect.width, height: rect.height)
    }

    // MARK: Helpers

    private static func nearest(
        to value: CGFloat,
        in edges: [Edge],
        overlapping span: ClosedRange<CGFloat>,
        threshold: CGFloat
    ) -> CGFloat? {
        guard threshold > 0 else { return nil }
        var best: CGFloat?
        var bestDistance = threshold
        for edge in edges {
            let distance = abs(edge.position - value)
            guard distance <= bestDistance else { continue }
            if let edgeSpan = edge.span {
                // Allow the threshold on the other axis too, so a corner just
                // outside a window still snaps to its extended edges.
                let widened = (edgeSpan.lowerBound - threshold)...(edgeSpan.upperBound + threshold)
                guard widened.overlaps(span) else { continue }
            }
            if distance < bestDistance || best == nil {
                best = edge.position
                bestDistance = distance
            }
        }
        return best
    }

    private static func smallerCorrection(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        switch (a == 0, b == 0) {
        case (true, true): 0
        case (false, true): a
        case (true, false): b
        case (false, false): abs(a) <= abs(b) ? a : b
        }
    }
}

/// Which edges of a rect move (Quartz: `minY` is the top edge).
public struct RectEdges: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let minX = RectEdges(rawValue: 1 << 0)
    public static let maxX = RectEdges(rawValue: 1 << 1)
    public static let minY = RectEdges(rawValue: 1 << 2)
    public static let maxY = RectEdges(rawValue: 1 << 3)
    public static let all: RectEdges = [.minX, .maxX, .minY, .maxY]
}
