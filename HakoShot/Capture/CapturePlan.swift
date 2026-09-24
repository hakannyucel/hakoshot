import CoreGraphics
import HakoKit

/// Pure planning for a rect capture: which displays it touches, what to ask
/// each display for, and where each piece lands in the output image. No
/// ScreenCaptureKit here, so it's unit-tested in `HakoShotTests/Capture`.
nonisolated struct CapturePlan: Equatable, Sendable {
    struct Piece: Equatable, Sendable {
        var displayID: CGDirectDisplayID
        /// Region to capture, in the display's local points (top-left origin),
        /// i.e. `SCStreamConfiguration.sourceRect`.
        var sourceRect: CGRect
        /// Pixel size to request (`sourceRect.size × outputScale`), so the
        /// piece is already at output resolution.
        var pixelWidth: Int
        var pixelHeight: Int
        /// Where the piece goes in the output image, pixels, top-left origin.
        var destination: CGRect
    }

    var rect: GlobalRect
    /// The largest backing scale among the touched displays (plan §4.7).
    var outputScale: CGFloat
    var pixelWidth: Int
    var pixelHeight: Int
    var pieces: [Piece]

    var isSingleDisplay: Bool { pieces.count == 1 }

    /// Returns `nil` if `rect` is empty or doesn't touch any display.
    static func make(rect: GlobalRect, layout: DisplayLayout) -> CapturePlan? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let touched = ScreenGeometry.displays(intersecting: rect, layout: layout)
        guard !touched.isEmpty else { return nil }
        let scale = touched.map(\.backingScaleFactor).max() ?? 1

        let pieces: [Piece] = touched.compactMap { display in
            guard let frame = ScreenGeometry.globalFrame(of: display, layout: layout) else { return nil }
            let part = rect.intersection(frame)
            guard part.width > 0, part.height > 0 else { return nil }
            let local = CGRect(
                x: part.minX - frame.minX, y: part.minY - frame.minY,
                width: part.width, height: part.height
            )
            let destination = CGRect(
                x: pixels(part.minX - rect.minX, scale), y: pixels(part.minY - rect.minY, scale),
                width: pixels(part.width, scale), height: pixels(part.height, scale)
            )
            return Piece(
                displayID: display.id,
                sourceRect: local,
                pixelWidth: Int(pixels(part.width, scale)),
                pixelHeight: Int(pixels(part.height, scale)),
                destination: destination
            )
        }
        guard !pieces.isEmpty else { return nil }
        return CapturePlan(
            rect: rect, outputScale: scale,
            pixelWidth: Int(pixels(rect.width, scale)), pixelHeight: Int(pixels(rect.height, scale)),
            pieces: pieces
        )
    }

    /// Points → whole pixels at `scale`.
    static func pixels(_ points: CGFloat, _ scale: CGFloat) -> CGFloat {
        (points * scale).rounded()
    }
}
