import CoreGraphics
import Foundation

/// Edge or corner of a pin window grabbed for resizing.
nonisolated enum PinEdge: Sendable, CaseIterable, Equatable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var movesLeft: Bool { self == .left || self == .topLeft || self == .bottomLeft }
    var movesRight: Bool { self == .right || self == .topRight || self == .bottomRight }
    var movesTop: Bool { self == .top || self == .topLeft || self == .topRight }
    var movesBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var isCorner: Bool { (movesLeft || movesRight) && (movesTop || movesBottom) }
}

/// Arrow-key nudge direction.
nonisolated enum PinNudge: Sendable, Equatable {
    case left, right, up, down
}

/// Pure pin-window math (zoom, aspect-locked resize, opacity, placement).
/// All rects are in AppKit screen space (bottom-left origin, y grows up).
nonisolated enum PinGeometry {
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 5
    static let minOpacity: Double = 0.1
    static let maxOpacity: Double = 1
    /// A pin never gets narrower/shorter than this (unless the image itself is smaller).
    static let minSide: CGFloat = 32

    // MARK: Opacity / zoom values

    static func clampOpacity(_ value: Double) -> Double {
        min(max(value, minOpacity), maxOpacity)
    }

    /// Smallest zoom that keeps both sides ≥ `minSide` (or 100 % for tiny images).
    static func minimumZoom(for baseSize: CGSize) -> CGFloat {
        let shortSide = min(baseSize.width, baseSize.height)
        guard shortSide > 0 else { return 1 }
        return min(1, max(minZoom, minSide / shortSide))
    }

    static func clampZoom(_ zoom: CGFloat, baseSize: CGSize) -> CGFloat {
        min(max(zoom, minimumZoom(for: baseSize)), maxZoom)
    }

    static func zoom(for size: CGSize, baseSize: CGSize) -> CGFloat {
        guard baseSize.width > 0 else { return 1 }
        return size.width / baseSize.width
    }

    /// "70%" style label.
    static func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    // MARK: Frames

    /// `frame` scaled to `zoom` × `baseSize`, keeping `anchor` (a point in the
    /// same space, usually the pointer) at the same relative spot.
    static func zoomedFrame(_ frame: CGRect, baseSize: CGSize, zoom: CGFloat, anchor: CGPoint) -> CGRect {
        let clamped = clampZoom(zoom, baseSize: baseSize)
        let newSize = CGSize(width: baseSize.width * clamped, height: baseSize.height * clamped)
        guard frame.width > 0, frame.height > 0 else { return CGRect(origin: frame.origin, size: newSize) }
        let relX = (anchor.x - frame.minX) / frame.width
        let relY = (anchor.y - frame.minY) / frame.height
        let origin = CGPoint(x: anchor.x - relX * newSize.width, y: anchor.y - relY * newSize.height)
        return CGRect(origin: origin, size: newSize).integralOrigin
    }

    /// Aspect-locked resize from `edge`. `translation` is the pointer movement
    /// since the drag began (AppKit: +y is up). The opposite edge/corner stays
    /// fixed; side drags keep the top-left (left/right) or left (top/bottom) fixed.
    static func resizedFrame(start: CGRect, edge: PinEdge, translation: CGSize, baseSize: CGSize) -> CGRect {
        guard baseSize.width > 0, baseSize.height > 0 else { return start }
        let aspect = baseSize.width / baseSize.height

        var widthFromX: CGFloat?
        if edge.movesRight { widthFromX = start.width + translation.width }
        if edge.movesLeft { widthFromX = start.width - translation.width }
        var widthFromY: CGFloat?
        if edge.movesTop { widthFromY = (start.height + translation.height) * aspect }
        if edge.movesBottom { widthFromY = (start.height - translation.height) * aspect }

        let proposed: CGFloat
        switch (widthFromX, widthFromY) {
        case let (x?, y?):
            proposed = abs(x - start.width) >= abs(y - start.width) ? x : y
        case let (x?, nil):
            proposed = x
        case let (nil, y?):
            proposed = y
        case (nil, nil):
            proposed = start.width
        }

        let zoom = clampZoom(proposed / baseSize.width, baseSize: baseSize)
        let width = (baseSize.width * zoom).rounded()
        let height = (baseSize.height * zoom).rounded()

        let x = edge.movesLeft ? start.maxX - width : start.minX
        let y: CGFloat
        if edge.movesBottom {
            y = start.maxY - height          // top fixed
        } else if edge.movesTop {
            y = start.minY                   // bottom fixed
        } else {
            y = start.maxY - height          // side drag: top fixed
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The edge/corner under `point` (view coordinates, y up) within `band` of the border.
    static func edge(at point: CGPoint, in bounds: CGRect, band: CGFloat) -> PinEdge? {
        guard bounds.insetBy(dx: -1, dy: -1).contains(point) else { return nil }
        // Corners get a slightly larger hit zone so they are easy to grab.
        let corner = band * 2
        let nearLeft = point.x - bounds.minX <= band
        let nearRight = bounds.maxX - point.x <= band
        let nearBottom = point.y - bounds.minY <= band
        let nearTop = bounds.maxY - point.y <= band
        let cornerLeft = point.x - bounds.minX <= corner
        let cornerRight = bounds.maxX - point.x <= corner
        let cornerBottom = point.y - bounds.minY <= corner
        let cornerTop = bounds.maxY - point.y <= corner

        if (nearTop && cornerLeft) || (nearLeft && cornerTop) { return .topLeft }
        if (nearTop && cornerRight) || (nearRight && cornerTop) { return .topRight }
        if (nearBottom && cornerLeft) || (nearLeft && cornerBottom) { return .bottomLeft }
        if (nearBottom && cornerRight) || (nearRight && cornerBottom) { return .bottomRight }
        if nearLeft { return .left }
        if nearRight { return .right }
        if nearTop { return .top }
        if nearBottom { return .bottom }
        return nil
    }

    /// Arrow-key move: 1 pt, 10 pt with ⇧.
    static func nudged(_ origin: CGPoint, _ direction: PinNudge, largeStep: Bool) -> CGPoint {
        let step: CGFloat = largeStep ? 10 : 1
        switch direction {
        case .left: return CGPoint(x: origin.x - step, y: origin.y)
        case .right: return CGPoint(x: origin.x + step, y: origin.y)
        case .up: return CGPoint(x: origin.x, y: origin.y + step)
        case .down: return CGPoint(x: origin.x, y: origin.y - step)
        }
    }

    /// Frame for a new pin without a source position: centered in `visibleFrame`,
    /// scaled down (never up) to fit within `fitFraction` of it.
    static func centeredFrame(pointSize: CGSize, in visibleFrame: CGRect, fitFraction: CGFloat = 0.9) -> CGRect {
        let zoom = fittingZoom(pointSize: pointSize, in: visibleFrame, fitFraction: fitFraction)
        let size = CGSize(width: (pointSize.width * zoom).rounded(), height: (pointSize.height * zoom).rounded())
        let origin = CGPoint(x: visibleFrame.midX - size.width / 2, y: visibleFrame.midY - size.height / 2)
        return CGRect(origin: origin, size: size).integralOrigin
    }

    /// ≤ 1 zoom so `pointSize` fits inside `fitFraction` of `visibleFrame`.
    static func fittingZoom(pointSize: CGSize, in visibleFrame: CGRect, fitFraction: CGFloat = 0.9) -> CGFloat {
        guard pointSize.width > 0, pointSize.height > 0 else { return 1 }
        let fit = min(
            visibleFrame.width * fitFraction / pointSize.width,
            visibleFrame.height * fitFraction / pointSize.height
        )
        return min(1, max(fit, minimumZoom(for: pointSize)))
    }
}

private extension CGRect {
    nonisolated var integralOrigin: CGRect {
        CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
