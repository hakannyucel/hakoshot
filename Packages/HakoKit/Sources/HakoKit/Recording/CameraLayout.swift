import CoreGraphics
import Foundation

/// Webcam bubble geometry (plan §4.8), shared by the live bubble window
/// (R4.2) and consistent with the Studio render (`StudioFrameState.cameraLayoutFor`:
/// same margin, squircle fraction, rectangle radius and 16:9 / 9:16 aspects).
///
/// Every function works in any rect space. `yAxis` says which way "top" is:
/// `.down` (Quartz global points, canvas pixels: top = `minY`) or `.up`
/// (AppKit screen coordinates: top = `maxY`). Corner names always mean what
/// the user sees.
public enum CameraLayout {
    public enum YAxis: Sendable, Hashable {
        /// Top = `minY` (Quartz, canvas pixels).
        case down
        /// Top = `maxY` (AppKit).
        case up
    }

    /// Distance from the recorded rect's edge (matches `StudioFrameState.cameraMargin`).
    public static let defaultMargin = StudioFrameState.cameraMargin
    /// Squircle corner radius as a fraction of the shorter side.
    public static let squircleCornerFraction = StudioFrameState.cameraSquircleCornerFraction
    /// Corner radius of the 16:9 / 9:16 shapes.
    public static let rectangleCornerRadius = StudioFrameState.cameraRectangleCornerRadius
    /// The bubble's shorter side never exceeds this fraction of the bounds'
    /// shorter side (a Large bubble in a small recorded area stays a bubble).
    public static let maxBoundsFraction = 0.5
    /// Smallest shorter side the bubble shrinks to.
    public static let minimumShortSide = 32.0

    // MARK: Size

    /// Bubble size for a shorter side of `shortSide` (the Small / Medium /
    /// Large setting, points) and `shape`'s aspect, scaled down (aspect kept)
    /// to fit `bounds` (the recorded rect): shorter side ≤ `maxBoundsFraction`
    /// of the bounds' shorter side and the whole bubble inside the bounds
    /// inset by `margin`. Whole points.
    public static func bubbleSize(
        shortSide: Double,
        shape: StudioCameraShape,
        fitting bounds: CGSize? = nil,
        margin: Double = defaultMargin
    ) -> CGSize {
        let aspect = shape.aspect
        var side = max(shortSide.isFinite ? shortSide : minimumShortSide, 1)
        if let bounds, bounds.width > 0, bounds.height > 0 {
            side = min(side, maxBoundsFraction * min(bounds.width, bounds.height))
            let availableW = max(bounds.width - 2 * margin, 1)
            let availableH = max(bounds.height - 2 * margin, 1)
            // Long side along x for aspect ≥ 1, along y otherwise.
            let fullW = aspect >= 1 ? side * aspect : side
            let fullH = aspect >= 1 ? side : side / aspect
            let fit = min(1, availableW / fullW, availableH / fullH)
            side *= fit
            side = max(side, min(minimumShortSide, min(bounds.width, bounds.height)))
        }
        let size = aspect >= 1
            ? CGSize(width: side * aspect, height: side)
            : CGSize(width: side, height: side / aspect)
        return CGSize(width: max(size.width.rounded(), 1), height: max(size.height.rounded(), 1))
    }

    // MARK: Placement

    /// The bubble frame of `size` in `corner` of `bounds`, `margin` from both
    /// edges (clamped inside the bounds when the margin doesn't fit).
    public static func frame(
        size: CGSize,
        corner: StudioCameraCorner,
        in bounds: CGRect,
        margin: Double = defaultMargin,
        yAxis: YAxis = .down
    ) -> CGRect {
        let left = bounds.minX + margin
        let right = bounds.maxX - margin - size.width
        let low = bounds.minY + margin                     // minY side
        let high = bounds.maxY - margin - size.height      // maxY side
        let x = corner.isLeft ? left : right
        let top = yAxis == .down ? low : high
        let bottom = yAxis == .down ? high : low
        let y = corner.isTop ? top : bottom
        return clamp(CGRect(x: x, y: y, width: size.width, height: size.height), in: bounds)
    }

    /// The corner whose quadrant holds `frame`'s center.
    public static func nearestCorner(to frame: CGRect, in bounds: CGRect, yAxis: YAxis = .down) -> StudioCameraCorner {
        let isLeft = frame.midX < bounds.midX
        let inMinYHalf = frame.midY < bounds.midY
        let isTop = yAxis == .down ? inMinYHalf : !inMinYHalf
        return StudioCameraCorner(isTop: isTop, isLeft: isLeft)
    }

    /// Drag end: the nearest corner and the frame snapped there.
    public static func snapped(
        _ frame: CGRect,
        in bounds: CGRect,
        margin: Double = defaultMargin,
        yAxis: YAxis = .down
    ) -> (corner: StudioCameraCorner, frame: CGRect) {
        let corner = nearestCorner(to: frame, in: bounds, yAxis: yAxis)
        return (corner, self.frame(size: frame.size, corner: corner, in: bounds, margin: margin, yAxis: yAxis))
    }

    /// `frame` moved (not resized) to lie inside `bounds`. A frame larger
    /// than the bounds on an axis is centered on that axis.
    public static func clamp(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        func axis(_ origin: Double, _ length: Double, _ lo: Double, _ hi: Double) -> Double {
            if length >= hi - lo { return lo + ((hi - lo) - length) / 2 }
            return min(max(origin, lo), hi - length)
        }
        return CGRect(
            x: axis(frame.minX, frame.width, bounds.minX, bounds.maxX),
            y: axis(frame.minY, frame.height, bounds.minY, bounds.maxY),
            width: frame.width,
            height: frame.height
        )
    }

    /// Where a drag puts the bubble: its start frame moved by the pointer
    /// delta, clamped inside the bounds.
    public static func dragged(_ start: CGRect, by delta: CGVector, in bounds: CGRect) -> CGRect {
        clamp(start.offsetBy(dx: delta.dx, dy: delta.dy), in: bounds)
    }

    // MARK: Shape

    /// Corner radius of the shape mask for a bubble of `size`: circle = half
    /// the shorter side, squircle = `squircleCornerFraction` of it, 16:9 /
    /// 9:16 = `rectangleRadius` (capped at half the shorter side).
    public static func cornerRadius(
        shape: StudioCameraShape,
        size: CGSize,
        rectangleRadius: Double = rectangleCornerRadius
    ) -> Double {
        let short = min(size.width, size.height)
        switch shape {
        case .circle: return short / 2
        case .squircle: return short * squircleCornerFraction
        case .rectangle, .vertical: return min(rectangleRadius, short / 2)
        }
    }

    /// The shape mask for `rect` (rounded rect / circle).
    public static func maskPath(shape: StudioCameraShape, in rect: CGRect, rectangleRadius: Double = rectangleCornerRadius) -> CGPath {
        if shape == .circle {
            return CGPath(ellipseIn: rect, transform: nil)
        }
        let radius = cornerRadius(shape: shape, size: rect.size, rectangleRadius: rectangleRadius)
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Whether `point` lies inside the shape mask of `rect`.
    public static func maskContains(_ point: CGPoint, shape: StudioCameraShape, in rect: CGRect) -> Bool {
        maskPath(shape: shape, in: rect).contains(point)
    }

    // MARK: Video fill

    /// Aspect-fill crop of a `source`-sized camera frame for a bubble of
    /// `bubble` size: the centered source rect (source units) that is shown.
    public static func aspectFillCrop(source: CGSize, bubble: CGSize) -> CGRect {
        guard source.width > 0, source.height > 0, bubble.width > 0, bubble.height > 0 else {
            return CGRect(origin: .zero, size: source)
        }
        let scale = max(bubble.width / source.width, bubble.height / source.height)
        let w = bubble.width / scale
        let h = bubble.height / scale
        return CGRect(x: (source.width - w) / 2, y: (source.height - h) / 2, width: w, height: h)
    }

    // MARK: Time

    /// `RecordingMetadata.cameraTimeOffset`: add it to a screen media time to
    /// get the `camera.mov` time (`StudioFrameState` does). `screenOrigin` =
    /// host seconds of the first screen frame (media time 0), `cameraOrigin`
    /// = host seconds of the first camera frame. Pauses cut the same host
    /// ranges from both files, so the offset holds throughout.
    public static func cameraTimeOffset(screenOrigin: Double, cameraOrigin: Double) -> Double {
        screenOrigin - cameraOrigin
    }
}

extension StudioCameraCorner {
    public var isTop: Bool { self == .topLeft || self == .topRight }
    public var isLeft: Bool { self == .topLeft || self == .bottomLeft }

    public init(isTop: Bool, isLeft: Bool) {
        switch (isTop, isLeft) {
        case (true, true): self = .topLeft
        case (true, false): self = .topRight
        case (false, true): self = .bottomLeft
        case (false, false): self = .bottomRight
        }
    }
}
