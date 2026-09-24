import CoreGraphics
import Foundation
import HakoKit

/// One finished capture, before any post-capture action (plan §3.2).
nonisolated struct CaptureResult: Sendable {
    /// Full-resolution pixels (points × scale).
    var image: CGImage
    /// Size in points; `image` is `pointSize × scale` pixels.
    var pointSize: CGSize
    /// Backing scale factor of the source display (2.0 on Retina).
    var scale: CGFloat
    var mode: CaptureMode
    /// Captured rect in Quartz global points; `nil` for window captures.
    var sourceRect: GlobalRect?
    var displayID: CGDirectDisplayID?
    var date: Date

    init(
        image: CGImage,
        pointSize: CGSize,
        scale: CGFloat,
        mode: CaptureMode,
        sourceRect: GlobalRect? = nil,
        displayID: CGDirectDisplayID? = nil,
        date: Date = .now
    ) {
        self.image = image
        self.pointSize = pointSize
        self.scale = scale
        self.mode = mode
        self.sourceRect = sourceRect
        self.displayID = displayID
        self.date = date
    }
}
