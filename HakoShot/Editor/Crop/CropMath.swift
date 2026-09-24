import CoreGraphics
import Foundation
import HakoKit

/// Crop mode aspect ratio (report §9.4: "Freeform" dropdown).
nonisolated enum CropAspect: Hashable, Sendable {
    case freeform
    /// The uncropped image's proportions.
    case original
    case ratio(width: Double, height: Double)

    /// Menu order: free, original, landscape presets, portrait presets.
    static let menu: [CropAspect] = [
        .freeform, .original,
        .ratio(width: 1, height: 1), .ratio(width: 4, height: 3), .ratio(width: 3, height: 2),
        .ratio(width: 16, height: 9), .ratio(width: 16, height: 10),
        .ratio(width: 3, height: 4), .ratio(width: 2, height: 3), .ratio(width: 9, height: 16),
    ]

    var label: String {
        switch self {
        case .freeform: "Freeform"
        case .original: "Original"
        case .ratio(let w, let h): "\(Self.format(w)):\(Self.format(h))"
        }
    }

    /// `width / height`, `nil` for freeform.
    func value(original: CGSize) -> CGFloat? {
        switch self {
        case .freeform: nil
        case .original: original.height > 0 ? original.width / original.height : nil
        case .ratio(let w, let h): w > 0 && h > 0 ? w / h : nil
        }
    }

    private static func format(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }
}

/// The eight crop handles.
nonisolated enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// -1 = moves minX, +1 = moves maxX, 0 = no horizontal edge.
    var xEdge: Int {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .topRight, .right, .bottomRight: 1
        case .top, .bottom: 0
        }
    }

    /// -1 = moves minY (top), +1 = moves maxY, 0 = none.
    var yEdge: Int {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .bottomLeft, .bottom, .bottomRight: 1
        case .left, .right: 0
        }
    }

    var isCorner: Bool { xEdge != 0 && yEdge != 0 }

    func position(in rect: CGRect) -> CGPoint {
        let x: CGFloat = switch xEdge { case -1: rect.minX; case 1: rect.maxX; default: rect.midX }
        let y: CGFloat = switch yEdge { case -1: rect.minY; case 1: rect.maxY; default: rect.midY }
        return CGPoint(x: x, y: y)
    }

    /// Corner handle pointing from `anchor` towards `point` (for drawing a new rect).
    static func corner(from anchor: CGPoint, to point: CGPoint) -> CropHandle {
        switch (point.x >= anchor.x, point.y >= anchor.y) {
        case (true, true): .bottomRight
        case (true, false): .topRight
        case (false, true): .bottomLeft
        case (false, false): .topLeft
        }
    }
}

/// Edges a crop edge may snap to, in display pixels.
nonisolated struct CropSnapTargets: Equatable, Sendable {
    var xs: [CGFloat]
    var ys: [CGFloat]

    static let none = CropSnapTargets(xs: [], ys: [])

    /// Bounds edges plus every rect's edges (clipped to the bounds).
    init(bounds: CGRect, rects: [CGRect]) {
        var xs: [CGFloat] = [bounds.minX, bounds.maxX]
        var ys: [CGFloat] = [bounds.minY, bounds.maxY]
        for rect in rects where !rect.isNull && rect.intersects(bounds) {
            for x in [rect.minX, rect.maxX] where x > bounds.minX && x < bounds.maxX { xs.append(x.rounded()) }
            for y in [rect.minY, rect.maxY] where y > bounds.minY && y < bounds.maxY { ys.append(y.rounded()) }
        }
        self.xs = xs
        self.ys = ys
    }

    init(xs: [CGFloat], ys: [CGFloat]) {
        self.xs = xs
        self.ys = ys
    }
}

/// Pure crop-rect math in *display pixels*: the uncropped image with the
/// document's rotate/flip applied, origin top-left (what crop mode shows).
nonisolated enum CropMath {
    /// Smallest crop side, pixels.
    static let minimumSide: CGFloat = 16

    // MARK: Display space

    /// Canvas pixels → display pixels for crop mode (rotate/flip, no crop).
    static func displayTransform(of document: ProjectDocument) -> CGAffineTransform {
        var uncropped = document
        uncropped.crop = nil
        return DocumentRenderer.contentTransform(of: uncropped)
    }

    /// The whole uncropped image in display pixels.
    static func displayBounds(of document: ProjectDocument) -> CGRect {
        var uncropped = document
        uncropped.crop = nil
        return CGRect(origin: .zero, size: DocumentRenderer.contentSize(of: uncropped))
    }

    /// The document's current crop (or everything) in display pixels.
    static func displayRect(of document: ProjectDocument) -> CGRect {
        let bounds = displayBounds(of: document)
        guard let crop = document.crop else { return bounds }
        return rounded(crop.applying(displayTransform(of: document))).intersection(bounds)
    }

    /// Display rect → the `setCrop` value (`nil` when it covers everything).
    static func canvasCrop(for displayRect: CGRect, in document: ProjectDocument) -> CGRect? {
        let bounds = displayBounds(of: document)
        let rect = rounded(displayRect).intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        if rect == bounds { return nil }
        return rounded(rect.applying(displayTransform(of: document).inverted()))
    }

    static func rounded(_ rect: CGRect) -> CGRect {
        let r = rect.standardized
        let minX = r.minX.rounded(), minY = r.minY.rounded()
        return CGRect(x: minX, y: minY, width: r.maxX.rounded() - minX, height: r.maxY.rounded() - minY)
    }

    // MARK: Snapping

    /// `value` moved to the nearest target within `tolerance`.
    static func snap(_ value: CGFloat, to targets: [CGFloat], tolerance: CGFloat) -> CGFloat {
        guard tolerance > 0, let nearest = targets.min(by: { abs($0 - value) < abs($1 - value) }),
              abs(nearest - value) <= tolerance else { return value }
        return nearest
    }

    /// Smallest correction that snaps either `a` or `b` to a target (0 if none).
    static func snapOffset(_ a: CGFloat, _ b: CGFloat, to targets: [CGFloat], tolerance: CGFloat) -> CGFloat {
        var best: CGFloat?
        for value in [a, b] {
            let snapped = snap(value, to: targets, tolerance: tolerance)
            let delta = snapped - value
            if snapped != value, best.map({ abs(delta) < abs($0) }) ?? true { best = delta }
        }
        return best ?? 0
    }

    // MARK: Ratio

    /// Largest rect of `ratio` inside `rect`, centered on it (choosing a ratio
    /// from the menu).
    static func fitted(ratio: CGFloat, in rect: CGRect) -> CGRect {
        guard ratio > 0, rect.width > 0, rect.height > 0 else { return rect }
        var size = CGSize(width: rect.width, height: rect.width / ratio)
        if size.height > rect.height { size = CGSize(width: rect.height * ratio, height: rect.height) }
        return rounded(CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height))
    }

    // MARK: Resize

    /// Drags `handle` of `rect` to `point`, keeping the opposite edge / corner
    /// fixed, `ratio` (w/h) if given, inside `bounds`, at least `minimumSide`.
    static func resize(
        _ rect: CGRect,
        handle: CropHandle,
        to point: CGPoint,
        ratio: CGFloat?,
        bounds: CGRect,
        snap targets: CropSnapTargets = .none,
        tolerance: CGFloat = 0
    ) -> CGRect {
        var p = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        if handle.xEdge != 0 { p.x = snap(p.x, to: targets.xs, tolerance: tolerance) }
        if handle.yEdge != 0 { p.y = snap(p.y, to: targets.ys, tolerance: tolerance) }
        let minSide = min(minimumSide, bounds.width, bounds.height)

        guard let ratio, ratio > 0 else {
            var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
            switch handle.xEdge {
            case -1: minX = min(p.x, maxX - minSide)
            case 1: maxX = max(p.x, minX + minSide)
            default: break
            }
            switch handle.yEdge {
            case -1: minY = min(p.y, maxY - minSide)
            case 1: maxY = max(p.y, minY + minSide)
            default: break
            }
            return rounded(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).intersection(bounds))
        }

        // Anchor: the fixed corner (corners) or the fixed edge's coordinate.
        let anchorX: CGFloat = handle.xEdge == 1 ? rect.minX : rect.maxX
        let anchorY: CGFloat = handle.yEdge == 1 ? rect.minY : rect.maxY
        // Room from the anchor towards the moving side.
        let roomX: CGFloat = handle.xEdge == 1 ? bounds.maxX - anchorX : anchorX - bounds.minX
        let roomY: CGFloat = handle.yEdge == 1 ? bounds.maxY - anchorY : anchorY - bounds.minY
        var width: CGFloat
        var height: CGFloat

        if handle.isCorner {
            let dx = max(CGFloat(handle.xEdge) * (p.x - anchorX), 0)
            let dy = max(CGFloat(handle.yEdge) * (p.y - anchorY), 0)
            width = max(dx, dy * ratio, minSide)
            height = width / ratio
            if width > roomX { width = roomX; height = width / ratio }
            if height > roomY { height = roomY; width = height * ratio }
            let x = handle.xEdge == 1 ? anchorX : anchorX - width
            let y = handle.yEdge == 1 ? anchorY : anchorY - height
            return rounded(CGRect(x: x, y: y, width: width, height: height))
        }

        if handle.xEdge != 0 {
            // Left / right edge: height follows, centered on the current middle.
            width = max(CGFloat(handle.xEdge) * (p.x - anchorX), minSide)
            width = min(width, roomX, bounds.height * ratio)
            height = width / ratio
            let x = handle.xEdge == 1 ? anchorX : anchorX - width
            let y = min(max(rect.midY - height / 2, bounds.minY), bounds.maxY - height)
            return rounded(CGRect(x: x, y: y, width: width, height: height))
        }
        // Top / bottom edge: width follows.
        height = max(CGFloat(handle.yEdge) * (p.y - anchorY), minSide)
        height = min(height, roomY, bounds.width / ratio)
        width = height * ratio
        let y = handle.yEdge == 1 ? anchorY : anchorY - height
        let x = min(max(rect.midX - width / 2, bounds.minX), bounds.maxX - width)
        return rounded(CGRect(x: x, y: y, width: width, height: height))
    }

    // MARK: Move

    /// `rect` moved by `delta`, kept inside `bounds`, edges snapped.
    static func move(
        _ rect: CGRect,
        by delta: CGVector,
        bounds: CGRect,
        snap targets: CropSnapTargets = .none,
        tolerance: CGFloat = 0
    ) -> CGRect {
        var moved = rect.offsetBy(dx: delta.dx, dy: delta.dy)
        moved.origin.x += snapOffset(moved.minX, moved.maxX, to: targets.xs, tolerance: tolerance)
        moved.origin.y += snapOffset(moved.minY, moved.maxY, to: targets.ys, tolerance: tolerance)
        moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
        moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
        return rounded(moved)
    }

    // MARK: Size fields

    /// W × H typed in the bar: keeps the center, stays inside `bounds`.
    static func resized(_ rect: CGRect, width: CGFloat, height: CGFloat, bounds: CGRect) -> CGRect {
        let minSide = min(minimumSide, bounds.width, bounds.height)
        let w = min(max(width.rounded(), minSide), bounds.width)
        let h = min(max(height.rounded(), minSide), bounds.height)
        let x = min(max(rect.midX - w / 2, bounds.minX), bounds.maxX - w)
        let y = min(max(rect.midY - h / 2, bounds.minY), bounds.maxY - h)
        return rounded(CGRect(x: x, y: y, width: w, height: h))
    }

    /// The other side for a typed side under `ratio`.
    static func linked(width: CGFloat, ratio: CGFloat) -> CGFloat { (width / ratio).rounded() }
    static func linked(height: CGFloat, ratio: CGFloat) -> CGFloat { (height * ratio).rounded() }

    // MARK: Hit testing

    /// Handle under `point` (within `tolerance` pixels), corners first.
    static func handle(at point: CGPoint, of rect: CGRect, tolerance: CGFloat) -> CropHandle? {
        let corners = CropHandle.allCases.filter(\.isCorner)
        let edges = CropHandle.allCases.filter { !$0.isCorner }
        for handle in corners {
            let p = handle.position(in: rect)
            if abs(p.x - point.x) <= tolerance, abs(p.y - point.y) <= tolerance { return handle }
        }
        // Edges: anywhere along the side.
        for handle in edges {
            let p = handle.position(in: rect)
            if handle.xEdge != 0, abs(p.x - point.x) <= tolerance, point.y >= rect.minY, point.y <= rect.maxY { return handle }
            if handle.yEdge != 0, abs(p.y - point.y) <= tolerance, point.x >= rect.minX, point.x <= rect.maxX { return handle }
        }
        return nil
    }
}

/// State of an open crop mode (report §9.4). Rects in display pixels.
nonisolated struct CropSession: Equatable, Sendable {
    /// The whole uncropped image.
    var bounds: CGRect
    /// The pending crop.
    var rect: CGRect
    var aspect: CropAspect = .freeform
    /// "Snap to edges" (⌘ held inverts it while dragging).
    var snapping = true
    /// Annotation bounds + image edges.
    var targets: CropSnapTargets

    init(document: ProjectDocument, snapping: Bool = true) {
        bounds = CropMath.displayBounds(of: document)
        rect = CropMath.displayRect(of: document)
        self.snapping = snapping
        let t = CropMath.displayTransform(of: document)
        targets = CropSnapTargets(bounds: bounds, rects: document.annotations.map { $0.bounds.applying(t) })
    }

    var ratio: CGFloat? { aspect.value(original: bounds.size) }

    /// Picks a ratio and fits the rect to it.
    mutating func setAspect(_ aspect: CropAspect) {
        self.aspect = aspect
        if let ratio { rect = CropMath.fitted(ratio: ratio, in: rect) }
    }

    mutating func setSize(width: CGFloat, height: CGFloat) {
        rect = CropMath.resized(rect, width: width, height: height, bounds: bounds)
    }

    /// "Revert to Original": the whole image, freeform.
    mutating func revert() {
        aspect = .freeform
        rect = bounds
    }

    var isFullImage: Bool { rect == bounds }
}
