import CoreGraphics
import HakoKit

/// What the selection overlay returns (plan §3.2).
nonisolated enum SelectionOutcome: Sendable {
    /// A rect in Quartz global points on the given display.
    case area(GlobalRect, displayID: CGDirectDisplayID)
    case window(CGWindowID)
    case fullscreen(displayID: CGDirectDisplayID)
    /// Area selected on a frozen snapshot; crop `snapshot` instead of capturing live.
    case frozenArea(GlobalRect, displayID: CGDirectDisplayID, snapshot: FrozenSnapshot)
    case cancelled
}

/// Pixels of one display taken before the overlay appeared (Freeze Screen, M3).
nonisolated struct FrozenSnapshot: Sendable {
    var image: CGImage
    var displayID: CGDirectDisplayID
    /// The display's frame in Quartz global points.
    var displayFrame: GlobalRect
    var scale: CGFloat
}
