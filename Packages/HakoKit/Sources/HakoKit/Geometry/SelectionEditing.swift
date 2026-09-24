import CoreGraphics

/// One of the 8 resize handles of an editable selection (plan §4.14).
/// Quartz orientation: `top` is `minY`.
public enum SelectionHandle: CaseIterable, Sendable, Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// The rect edges this handle moves.
    public var edges: RectEdges {
        switch self {
        case .topLeft: [.minX, .minY]
        case .top: [.minY]
        case .topRight: [.maxX, .minY]
        case .right: [.maxX]
        case .bottomRight: [.maxX, .maxY]
        case .bottom: [.maxY]
        case .bottomLeft: [.minX, .maxY]
        case .left: [.minX]
        }
    }

    public var isCorner: Bool {
        switch self {
        case .topLeft, .topRight, .bottomRight, .bottomLeft: true
        case .top, .right, .bottom, .left: false
        }
    }

    /// The handle's center on `rect`.
    public func point(on rect: GlobalRect) -> CGPoint {
        let x: CGFloat = edges.contains(.minX) ? rect.minX : edges.contains(.maxX) ? rect.maxX : rect.midX
        let y: CGFloat = edges.contains(.minY) ? rect.minY : edges.contains(.maxY) ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }
}

/// How the arrow keys change an editable selection (plan §5.4).
public enum SelectionNudgeKind: Sendable, Hashable {
    /// Move the whole selection.
    case move
    /// `⌥`: grow the selection by moving its right edge (←/→) or bottom edge (↑/↓) outward.
    case grow
    /// `⌃⌥`: shrink it by moving the right/bottom edge inward.
    case shrink
}

/// Pure math for editing an existing selection: handle hit testing, resize,
/// aspect-ratio drags and arrow-key nudges. Quartz global points throughout.
public enum SelectionEditing {
    /// Hit radius around a handle center (larger than the drawn handle).
    public static let handleHitRadius: CGFloat = 8
    /// Smallest selection a resize can produce.
    public static let minimumSize: CGFloat = 1

    // MARK: Hit testing

    /// The handle under `point`, if any. Corners win over edges. Edge handles
    /// cover the whole edge (not just the midpoint) so any part of a side can
    /// be grabbed.
    public static func handle(at point: CGPoint, of rect: GlobalRect, radius: CGFloat = handleHitRadius) -> SelectionHandle? {
        for handle in SelectionHandle.allCases where handle.isCorner {
            let c = handle.point(on: rect)
            if abs(point.x - c.x) <= radius && abs(point.y - c.y) <= radius { return handle }
        }
        let withinX = point.x >= rect.minX - radius && point.x <= rect.maxX + radius
        let withinY = point.y >= rect.minY - radius && point.y <= rect.maxY + radius
        if withinY && abs(point.x - rect.minX) <= radius { return .left }
        if withinY && abs(point.x - rect.maxX) <= radius { return .right }
        if withinX && abs(point.y - rect.minY) <= radius { return .top }
        if withinX && abs(point.y - rect.maxY) <= radius { return .bottom }
        return nil
    }

    // MARK: Resize

    /// `rect` with `handle` dragged to `point`, clamped to `bounds`. The
    /// opposite edges stay fixed; the moving edges cannot cross them (the
    /// selection keeps at least `minimumSize`). With `ratio` (width / height)
    /// the result keeps that aspect: corners follow the dominant axis, edge
    /// handles grow the other axis symmetrically.
    public static func resize(
        _ rect: GlobalRect,
        handle: SelectionHandle,
        to point: CGPoint,
        ratio: CGFloat? = nil,
        bounds: GlobalRect
    ) -> GlobalRect {
        let p = SelectionMath.clamp(point, to: bounds)
        let edges = handle.edges
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if edges.contains(.minX) { minX = min(p.x, maxX - minimumSize) }
        if edges.contains(.maxX) { maxX = max(p.x, minX + minimumSize) }
        if edges.contains(.minY) { minY = min(p.y, maxY - minimumSize) }
        if edges.contains(.maxY) { maxY = max(p.y, minY + minimumSize) }
        var result = GlobalRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard let ratio, ratio > 0 else { return result }

        if handle.isCorner {
            // Fixed corner = opposite of the handle.
            let anchor = CGPoint(
                x: edges.contains(.minX) ? rect.maxX : rect.minX,
                y: edges.contains(.minY) ? rect.maxY : rect.minY
            )
            let signX: CGFloat = edges.contains(.minX) ? -1 : 1
            let signY: CGFloat = edges.contains(.minY) ? -1 : 1
            let roomX = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
            let roomY = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
            let size = fitted(width: result.width, height: result.height, ratio: ratio, roomX: roomX, roomY: roomY)
            result = GlobalRect(
                x: signX > 0 ? anchor.x : anchor.x - size.width,
                y: signY > 0 ? anchor.y : anchor.y - size.height,
                width: size.width, height: size.height
            )
        } else if edges.contains(.minX) || edges.contains(.maxX) {
            // Width drives, height grows around the vertical center.
            let midY = rect.midY
            let halfRoom = min(midY - bounds.minY, bounds.maxY - midY)
            var height = result.width / ratio
            var width = result.width
            if height / 2 > halfRoom {
                height = halfRoom * 2
                width = height * ratio
            }
            let x = edges.contains(.minX) ? rect.maxX - width : rect.minX
            result = GlobalRect(x: x, y: midY - height / 2, width: width, height: height)
        } else {
            let midX = rect.midX
            let halfRoom = min(midX - bounds.minX, bounds.maxX - midX)
            var width = result.height * ratio
            var height = result.height
            if width / 2 > halfRoom {
                width = halfRoom * 2
                height = width / ratio
            }
            let y = edges.contains(.minY) ? rect.maxY - height : rect.minY
            result = GlobalRect(x: midX - width / 2, y: y, width: width, height: height)
        }
        return result
    }

    /// A new drag from `anchor` to `current` locked to `ratio` (width /
    /// height), clamped to `bounds`. The larger implied size wins, then the
    /// rect shrinks as a whole to fit.
    public static func rect(anchor rawAnchor: CGPoint, current: CGPoint, ratio: CGFloat, bounds: GlobalRect) -> GlobalRect {
        let anchor = SelectionMath.clamp(rawAnchor, to: bounds)
        let dx = current.x - anchor.x
        let dy = current.y - anchor.y
        let signX: CGFloat = dx < 0 ? -1 : 1
        let signY: CGFloat = dy < 0 ? -1 : 1
        let roomX = signX > 0 ? bounds.maxX - anchor.x : anchor.x - bounds.minX
        let roomY = signY > 0 ? bounds.maxY - anchor.y : anchor.y - bounds.minY
        let size = fitted(width: abs(dx), height: abs(dy), ratio: max(ratio, .leastNonzeroMagnitude), roomX: roomX, roomY: roomY)
        return GlobalRect(
            x: signX > 0 ? anchor.x : anchor.x - size.width,
            y: signY > 0 ? anchor.y : anchor.y - size.height,
            width: size.width, height: size.height
        )
    }

    /// The smallest size with `ratio` that covers `width`×`height`, then
    /// scaled down to fit `roomX`×`roomY`.
    static func fitted(width: CGFloat, height: CGFloat, ratio: CGFloat, roomX: CGFloat, roomY: CGFloat) -> CGSize {
        var w = width
        var h = height
        if h == 0 || w / h > ratio { h = w / ratio } else { w = h * ratio }
        if w > roomX {
            w = max(roomX, 0)
            h = w / ratio
        }
        if h > roomY {
            h = max(roomY, 0)
            w = h * ratio
        }
        return CGSize(width: w, height: h)
    }

    // MARK: Programmatic changes

    /// `rect` resized to `size` keeping its origin, then moved/clamped into
    /// `bounds` (size input in the All-In-One bar).
    public static func resized(_ rect: GlobalRect, to size: CGSize, within bounds: GlobalRect) -> GlobalRect {
        let w = min(max(size.width, minimumSize), bounds.width)
        let h = min(max(size.height, minimumSize), bounds.height)
        return fitted(GlobalRect(origin: rect.origin, size: CGSize(width: w, height: h)), within: bounds)
    }

    /// `rect` moved (not resized, unless larger than `bounds`) so it lies inside `bounds`.
    public static func fitted(_ rect: GlobalRect, within bounds: GlobalRect) -> GlobalRect {
        let w = min(rect.width, bounds.width)
        let h = min(rect.height, bounds.height)
        let x = min(max(rect.minX, bounds.minX), bounds.maxX - w)
        let y = min(max(rect.minY, bounds.minY), bounds.maxY - h)
        return GlobalRect(x: x, y: y, width: w, height: h)
    }

    /// Arrow-key change (plan §5.4): `.move` shifts by 1 pt (`large`: 10 pt);
    /// `.grow` / `.shrink` move the right edge (horizontal arrows) or the
    /// bottom edge (vertical arrows) by the same step.
    public static func nudged(
        _ rect: GlobalRect,
        _ direction: NudgeDirection,
        kind: SelectionNudgeKind,
        large: Bool,
        within bounds: GlobalRect
    ) -> GlobalRect {
        let step = large ? SelectionMath.largeNudgeStep : SelectionMath.nudgeStep
        var d = CGVector.zero
        switch direction {
        case .left: d.dx = -step
        case .right: d.dx = step
        case .up: d.dy = -step
        case .down: d.dy = step
        }
        switch kind {
        case .move:
            let applied = SelectionMath.clampedTranslation(of: rect, by: d, within: bounds)
            return GlobalRect(x: rect.minX + applied.dx, y: rect.minY + applied.dy, width: rect.width, height: rect.height)
        case .grow, .shrink:
            let sign: CGFloat = kind == .grow ? 1 : -1
            let dw = d.dx == 0 ? 0 : sign * step
            let dh = d.dy == 0 ? 0 : sign * step
            let w = min(max(rect.width + dw, minimumSize), bounds.maxX - rect.minX)
            let h = min(max(rect.height + dh, minimumSize), bounds.maxY - rect.minY)
            return GlobalRect(x: rect.minX, y: rect.minY, width: w, height: h)
        }
    }
}
