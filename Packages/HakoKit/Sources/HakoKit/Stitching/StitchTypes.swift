import Foundation

/// Scroll direction of a scrolling-capture session.
public enum StitchAxis: String, Sendable, Equatable, CaseIterable {
    /// Content moves up as the user scrolls down (the common case).
    case vertical
    /// Content moves left as the user scrolls right.
    case horizontal
}

/// Tunables for ``ScrollStitcher``. The defaults follow plan §4.8.
public struct ScrollStitcherConfiguration: Sendable, Equatable {
    /// Fixed axis, or `nil` to pick it automatically from the first frame pair
    /// that shows real movement.
    public var axis: StitchAxis?

    /// Pixels at the trailing edge (right edge for vertical, bottom edge for
    /// horizontal) ignored while matching, so overlay scroll bars that fade in
    /// and out do not break matches. Plan §4.8 says 16 px; on a Retina capture
    /// pass `16 * backingScale`.
    public var scrollBarInset: Int

    /// Minimum overlap between consecutive frames as a fraction of the moving
    /// band. Less than this counts as "too fast" (plan: 15 %).
    public var minimumOverlapFraction: Double

    /// Row-hash match ratio needed to accept an offset in the exact stage.
    public var matchThreshold: Double

    /// Mean luminance difference (0...255, per 1/32-width cell) tolerated by the
    /// fallback stage for noisy / anti-aliased frames.
    public var noiseTolerance: Float

    /// Hard cap of the stitched image along the scroll axis, in pixels.
    public var maximumLength: Int

    public init(
        axis: StitchAxis? = nil,
        scrollBarInset: Int = 16,
        minimumOverlapFraction: Double = 0.15,
        matchThreshold: Double = 0.9,
        noiseTolerance: Float = 4,
        maximumLength: Int = 32_000
    ) {
        self.axis = axis
        self.scrollBarInset = scrollBarInset
        self.minimumOverlapFraction = minimumOverlapFraction
        self.matchThreshold = matchThreshold
        self.noiseTolerance = noiseTolerance
        self.maximumLength = maximumLength
    }
}

/// What happened to a frame passed to ``ScrollStitcher/append(_:expectedDelta:)``.
public enum StitchEvent: Sendable, Equatable {
    /// First frame; it became the base of the stitched image.
    case started
    /// The frame matched the previous accepted frame and new content was added.
    case appended(StitchStep)
    /// Nothing moved (same content as the previous accepted frame). Three of
    /// these in a row during auto-scroll mean "end of content".
    case duplicate
    /// The frame was dropped; the previous accepted frame stays the reference,
    /// so the next frame is compared against it again.
    case rejected(StitchRejection)
    /// The stitched image reached ``ScrollStitcherConfiguration/maximumLength``.
    /// Further frames are ignored; the session should finish.
    case limitReached(totalLength: Int)

    /// `true` when the UI should show the "Slow down" badge.
    public var suggestsSlowingDown: Bool {
        if case .rejected(.tooFast) = self { return true }
        return false
    }
}

/// Details of an accepted frame.
public struct StitchStep: Sendable, Equatable {
    /// Content movement since the previous accepted frame, in pixels (> 0).
    public var offset: Int
    /// Pixels added to the stitched image by this frame.
    public var addedLength: Int
    /// Current stitched length along the axis (including the pending tail).
    public var totalLength: Int
    /// 0...1. Exact row-hash matches score 0.9...1, tolerant matches below 0.9.
    public var confidence: Double
    /// Several offsets fit equally well (repeating content); the hint or the
    /// "largest overlap" rule decided.
    public var ambiguous: Bool
    public var axis: StitchAxis

    public init(offset: Int, addedLength: Int, totalLength: Int, confidence: Double, ambiguous: Bool, axis: StitchAxis) {
        self.offset = offset
        self.addedLength = addedLength
        self.totalLength = totalLength
        self.confidence = confidence
        self.ambiguous = ambiguous
        self.axis = axis
    }
}

/// Why a frame was dropped.
public enum StitchRejection: Sendable, Equatable {
    /// No overlap with the previous accepted frame (scrolled too far between
    /// frames, or content changed too much). UI: "Slow down".
    case tooFast
    /// The content moved backwards by `offset` pixels; only forward scrolling
    /// is stitched.
    case backward(offset: Int)
    /// Frame size differs from the first frame.
    case sizeMismatch
    /// The image could not be converted to 32-bit pixels.
    case unreadableFrame
}
