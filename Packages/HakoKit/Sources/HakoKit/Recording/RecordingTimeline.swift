/// Maps host seconds to recording media time (plan §1.3, §4.6).
///
/// Media time 0 is `origin`: the host time of the first written screen frame
/// (T0). Every pause removes its host interval from media time, matching the
/// writer's `PTS − pauseOffset` retiming. Events inside a pause (or before
/// T0) have no media time and are dropped.
///
/// Pause intervals are half-open in practice: an event exactly at a pause's
/// `lowerBound` is dropped, one exactly at its `upperBound` (the resume
/// instant) maps to the pause start's media time.
public struct RecordingTimeline: Sendable, Hashable {
    /// Host seconds of media time 0.
    public var origin: Double
    /// Closed pauses in host seconds, sorted, non-overlapping.
    public private(set) var pauses: [ClosedRange<Double>]
    /// Host start of the pause in progress, if any.
    public private(set) var openPauseStart: Double?

    public init(origin: Double, pauses: [ClosedRange<Double>] = []) {
        self.origin = origin
        self.pauses = Self.normalized(pauses)
        self.openPauseStart = nil
    }

    public var isPaused: Bool { openPauseStart != nil }

    /// Starts a pause at `host`. No-op if already paused.
    public mutating func beginPause(at host: Double) {
        guard openPauseStart == nil else { return }
        openPauseStart = host
    }

    /// Ends the pause in progress at `host`. No-op if not paused.
    public mutating func endPause(at host: Double) {
        guard let start = openPauseStart else { return }
        openPauseStart = nil
        guard host > start else { return }
        pauses = Self.normalized(pauses + [start...host])
    }

    /// Total paused host seconds before `host` (the writer's `pauseOffset`),
    /// counting only the part of each pause after `origin`. An open pause
    /// counts up to `host`.
    public func pausedDuration(before host: Double) -> Double {
        var total = 0.0
        for pause in allPauses(openUntil: host) {
            let lower = max(pause.lowerBound, origin)
            let upper = min(pause.upperBound, host)
            if upper > lower { total += upper - lower }
        }
        return total
    }

    /// Media seconds for a host timestamp; `nil` before `origin` or inside a
    /// pause (including an open one).
    public func mediaTime(host: Double) -> Double? {
        guard host >= origin else { return nil }
        if let open = openPauseStart, host >= open { return nil }
        for pause in pauses where host >= pause.lowerBound && host < pause.upperBound {
            return nil
        }
        return host - origin - pausedDuration(before: host)
    }

    /// Host seconds for a media time (inverse of `mediaTime(host:)`); lands
    /// on the resume instant at pause boundaries.
    public func hostTime(media: Double) -> Double {
        var host = origin + max(media, 0)
        for pause in pauses {
            let lower = max(pause.lowerBound, origin)
            guard pause.upperBound > lower else { continue }
            if host >= lower { host += pause.upperBound - lower } else { break }
        }
        return host
    }

    /// Media duration when the recording stops at host `stop`
    /// (`stop − origin − pausedDuration`), never negative.
    public func mediaDuration(stoppedAt stop: Double) -> Double {
        max(0, stop - origin - pausedDuration(before: stop))
    }

    private func allPauses(openUntil host: Double) -> [ClosedRange<Double>] {
        guard let open = openPauseStart, host > open else { return pauses }
        return pauses + [open...host]
    }

    /// Sorts and merges overlapping/touching intervals.
    static func normalized(_ ranges: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<Double>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
