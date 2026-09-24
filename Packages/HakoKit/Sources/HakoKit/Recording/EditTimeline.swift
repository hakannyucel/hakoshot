import Foundation

/// A half-open time range `[start, end)` in seconds.
public struct EditTimeRange: Sendable, Hashable, Codable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    public var duration: Double { max(0, end - start) }
    public var isEmpty: Bool { !(end > start) }

    public func contains(_ time: Double) -> Bool { time >= start && time < end }
}

/// Trim plus cuts over a source video (plan §4.16, R3.1).
///
/// Times are in seconds. **Source time** is the position in the original
/// file; **output time** is the position in the edited result, where the
/// trimmed-away head/tail and every cut are removed and the kept segments
/// are joined back to back.
///
/// The initializer normalizes its input: the trim is clamped to
/// `[0, sourceDuration]`, cuts are clipped to the trim, empty cuts are
/// dropped, and overlapping or touching cuts are merged.
public struct EditTimeline: Sendable, Hashable {
    public let sourceDuration: Double
    /// Kept source range (after clamping).
    public let trim: EditTimeRange
    /// Removed source ranges inside `trim`: sorted, disjoint, non-empty.
    public let cuts: [EditTimeRange]
    /// Source ranges that make up the output, in order.
    public let segments: [EditTimeRange]

    public init(sourceDuration: Double, trim: EditTimeRange? = nil, cuts: [EditTimeRange] = []) {
        let duration = sourceDuration.isFinite ? max(0, sourceDuration) : 0
        self.sourceDuration = duration

        let wanted = trim ?? EditTimeRange(start: 0, end: duration)
        let start = Self.clamp(wanted.start, 0, duration)
        let end = Self.clamp(wanted.end, start, duration)
        let trimRange = EditTimeRange(start: start, end: end)
        self.trim = trimRange

        var clipped: [EditTimeRange] = []
        for cut in cuts where cut.start.isFinite && cut.end.isFinite {
            let s = max(cut.start, start), e = min(cut.end, end)
            if e > s { clipped.append(EditTimeRange(start: s, end: e)) }
        }
        clipped.sort { $0.start < $1.start }
        var merged: [EditTimeRange] = []
        for cut in clipped {
            if let last = merged.last, cut.start <= last.end {
                merged[merged.count - 1].end = max(last.end, cut.end)
            } else {
                merged.append(cut)
            }
        }
        self.cuts = merged

        var kept: [EditTimeRange] = []
        var cursor = start
        for cut in merged {
            if cut.start > cursor { kept.append(EditTimeRange(start: cursor, end: cut.start)) }
            cursor = cut.end
        }
        if end > cursor { kept.append(EditTimeRange(start: cursor, end: end)) }
        self.segments = kept
    }

    /// `true` when nothing is trimmed or cut.
    public var isIdentity: Bool {
        cuts.isEmpty && trim.start == 0 && trim.end == sourceDuration
    }

    /// Length of the edited result.
    public var outputDuration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Output time for a source time, or `nil` when that moment is trimmed
    /// or cut away.
    public func outputTime(forSource time: Double) -> Double? {
        var offset = 0.0
        for segment in segments {
            if segment.contains(time) { return offset + (time - segment.start) }
            offset += segment.duration
        }
        // The very end of the last segment maps to the output end.
        if let last = segments.last, time == last.end { return offset }
        return nil
    }

    /// Source time for an output time. Clamped to `[0, outputDuration]`; a
    /// time exactly on a join maps to the start of the later segment.
    public func sourceTime(forOutput time: Double) -> Double {
        guard let first = segments.first, let last = segments.last else { return trim.start }
        if !(time > 0) { return first.start }
        var remaining = time
        for segment in segments {
            if remaining < segment.duration { return segment.start + remaining }
            remaining -= segment.duration
        }
        return last.end
    }

    /// Number of output frames at `fps` (rounded).
    public func frameCount(fps: Double) -> Int {
        guard fps > 0, fps.isFinite else { return 0 }
        return Int((outputDuration * fps).rounded())
    }

    /// Copy with the trim and every cut edge snapped to the `fps` frame grid
    /// (plan §4.16: trim handles stick to frame boundaries).
    public func snapped(fps: Double) -> EditTimeline {
        let snap = { (t: Double) in Self.snap(t, fps: fps) }
        return EditTimeline(
            sourceDuration: sourceDuration,
            trim: EditTimeRange(start: snap(trim.start), end: min(snap(trim.end), sourceDuration)),
            cuts: cuts.map { EditTimeRange(start: snap($0.start), end: snap($0.end)) }
        )
    }

    /// Nearest frame boundary at `fps` (`round(t × fps) / fps`). Returns `t`
    /// unchanged for a non-positive fps.
    public static func snap(_ time: Double, fps: Double) -> Double {
        guard fps > 0, fps.isFinite, time.isFinite else { return time }
        return (time * fps).rounded() / fps
    }

    /// Frame index at `fps` that contains `time` (floor, with a tiny
    /// tolerance so exact boundaries don't fall into the previous frame).
    public static func frameIndex(at time: Double, fps: Double) -> Int {
        guard fps > 0, fps.isFinite, time.isFinite else { return 0 }
        return Int((time * fps + 1e-6).rounded(.down))
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        guard value.isFinite else { return low }
        return min(max(value, low), high)
    }
}
