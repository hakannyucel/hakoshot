import CoreGraphics

/// Modifier-driven constraints applied while dragging out a selection
/// (plan §4.1: `⇧` square, `⌥` symmetric from the press point).
public struct SelectionConstraints: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// Width == height (`⇧`).
    public static let square = SelectionConstraints(rawValue: 1 << 0)
    /// The press point is the rect's center, not a corner (`⌥`).
    public static let fromCenter = SelectionConstraints(rawValue: 1 << 1)
}

/// Arrow-key direction for cursor / selection nudging (plan §5.4).
public enum NudgeDirection: Sendable, Hashable, CaseIterable {
    case left, right, up, down
}

/// Pure selection geometry for the area overlay. Everything is in Quartz global
/// points (top-left origin, y grows downward — see `GlobalRect`).
public enum SelectionMath {
    /// Pointer travel (pt) below which a press + release counts as a click, not a drag.
    public static let minimumDragDistance: CGFloat = 3
    /// Arrow-key step (plan §5.4: 1 pt, `⇧` 10 pt).
    public static let nudgeStep: CGFloat = 1
    public static let largeNudgeStep: CGFloat = 10

    // MARK: Points

    /// `point` clamped into `bounds` (edges inclusive, so a selection can reach
    /// the display's right/bottom edge).
    public static func clamp(_ point: CGPoint, to bounds: GlobalRect) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    /// Whether the pointer moved far enough from `start` to start a drag.
    public static func isDrag(from start: CGPoint, to current: CGPoint) -> Bool {
        hypot(current.x - start.x, current.y - start.y) >= minimumDragDistance
    }

    /// `point` moved one arrow-key step. `large` = `⇧` held. If `bounds` is given
    /// the result is clamped into it.
    public static func nudge(
        _ point: CGPoint,
        _ direction: NudgeDirection,
        large: Bool,
        within bounds: GlobalRect? = nil
    ) -> CGPoint {
        let step = large ? largeNudgeStep : nudgeStep
        var moved = point
        switch direction {
        case .left: moved.x -= step
        case .right: moved.x += step
        case .up: moved.y -= step    // Quartz: y grows downward.
        case .down: moved.y += step
        }
        guard let bounds else { return moved }
        return clamp(moved, to: bounds)
    }

    // MARK: Rects

    /// The selection rect for a drag from `anchor` (press point) to `current`
    /// (pointer), honoring `constraints` and never leaving `bounds` (the display
    /// the drag started on). With `.square` / `.fromCenter` the rect shrinks as a
    /// whole rather than being cut, so the constraint still holds at the edges.
    public static func rect(
        anchor rawAnchor: CGPoint,
        current rawCurrent: CGPoint,
        constraints: SelectionConstraints = [],
        bounds: GlobalRect
    ) -> GlobalRect {
        let anchor = clamp(rawAnchor, to: bounds)
        let dx = rawCurrent.x - anchor.x
        let dy = rawCurrent.y - anchor.y
        let signX: CGFloat = dx < 0 ? -1 : 1
        let signY: CGFloat = dy < 0 ? -1 : 1

        // Room from the anchor to the bounds edge in the drag direction.
        let roomX = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let roomY = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY

        if constraints.contains(.fromCenter) {
            // Half extents are limited by the nearer edge on each axis.
            let halfRoomX = min(anchor.x - bounds.minX, bounds.maxX - anchor.x)
            let halfRoomY = min(anchor.y - bounds.minY, bounds.maxY - anchor.y)
            var halfW = abs(dx)
            var halfH = abs(dy)
            if constraints.contains(.square) {
                let half = min(max(halfW, halfH), halfRoomX, halfRoomY)
                halfW = half
                halfH = half
            } else {
                halfW = min(halfW, halfRoomX)
                halfH = min(halfH, halfRoomY)
            }
            return GlobalRect(x: anchor.x - halfW, y: anchor.y - halfH, width: halfW * 2, height: halfH * 2)
        }

        var width = min(abs(dx), roomX)
        var height = min(abs(dy), roomY)
        if constraints.contains(.square) {
            let side = min(max(abs(dx), abs(dy)), roomX, roomY)
            width = side
            height = side
        }
        let originX = signX > 0 ? anchor.x : anchor.x - width
        let originY = signY > 0 ? anchor.y : anchor.y - height
        return GlobalRect(x: originX, y: originY, width: width, height: height)
    }

    /// The part of `delta` that can be applied to `rect` without it leaving
    /// `bounds` (used for `Space`-drag moving). A rect larger than `bounds` on
    /// an axis does not move on that axis.
    public static func clampedTranslation(of rect: GlobalRect, by delta: CGVector, within bounds: GlobalRect) -> CGVector {
        func axis(_ d: CGFloat, min lo: CGFloat, max hi: CGFloat, boundsMin: CGFloat, boundsMax: CGFloat) -> CGFloat {
            let lowest = boundsMin - lo     // most negative allowed shift
            let highest = boundsMax - hi    // most positive allowed shift
            guard lowest <= highest else { return 0 }
            return min(max(d, lowest), highest)
        }
        return CGVector(
            dx: axis(delta.dx, min: rect.minX, max: rect.maxX, boundsMin: bounds.minX, boundsMax: bounds.maxX),
            dy: axis(delta.dy, min: rect.minY, max: rect.maxY, boundsMin: bounds.minY, boundsMax: bounds.maxY)
        )
    }

    /// `rect` snapped to the display's pixel grid: each edge is
    /// rounded to the nearest device pixel (`1 / scale` pt), then clamped into
    /// `bounds`. Capture then maps to whole pixels.
    public static func pixelAligned(_ rect: GlobalRect, scale: CGFloat, within bounds: GlobalRect) -> GlobalRect {
        let s = max(scale, 1)
        func snap(_ v: CGFloat) -> CGFloat { (v * s).rounded() / s }
        let minX = max(snap(rect.minX), bounds.minX)
        let minY = max(snap(rect.minY), bounds.minY)
        let maxX = min(snap(rect.maxX), bounds.maxX)
        let maxY = min(snap(rect.maxY), bounds.maxY)
        return GlobalRect(x: minX, y: minY, width: max(maxX - minX, 0), height: max(maxY - minY, 0))
    }

    /// Whether a finished selection is big enough to capture (at least one
    /// device pixel on each axis).
    public static func isCapturable(_ rect: GlobalRect, scale: CGFloat) -> Bool {
        let pixel = 1 / max(scale, 1)
        return rect.width >= pixel && rect.height >= pixel
    }
}
