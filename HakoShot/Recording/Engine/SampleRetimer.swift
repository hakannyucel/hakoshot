import CoreMedia
import Foundation

/// Pause bookkeeping and sample re-stamping for `RecordingWriter` (plan §4.6).
///
/// Samples keep their host-clock PTS from the source. After pauses, every
/// sample is written at `PTS − pauseOffset` (`pauseOffset` = total paused
/// host time after T0). Samples captured inside a pause are dropped:
/// - while paused, anything at or after the pause start;
/// - after a resume, anything stamped before the resume instant (late
///   deliveries from inside the pause);
/// - audio buffers that straddle a pause boundary are dropped whole
///   (≤ ~20 ms lost, plan §4.6 default).
///
/// Value type; `RecordingWriter` keeps it under its lock.
nonisolated struct SampleRetimer: Sendable, Equatable {
    /// Total paused host time counted into media time so far.
    private(set) var pauseOffset: CMTime = .zero
    /// Host start of the pause in progress.
    private(set) var pauseStart: CMTime?
    /// Host time of the last resume; samples before it are dropped.
    private(set) var resumeTime: CMTime?
    /// Closed pauses after T0, host seconds (for `RecordingTimeline`).
    private(set) var pauses: [ClosedRange<Double>] = []

    init() {}

    var isPaused: Bool { pauseStart != nil }

    /// Starts a pause at host `time`. No-op when already paused.
    mutating func pause(at time: CMTime) {
        guard pauseStart == nil else { return }
        pauseStart = time
    }

    /// Ends the pause at host `time`. `sessionStart` (T0) decides whether the
    /// pause counts: a pause that started before the first frame adds no
    /// offset (media time starts at the first frame after it). Returns the
    /// counted pause length (`.zero` when not paused / not counted).
    @discardableResult
    mutating func resume(at time: CMTime, sessionStart: CMTime?) -> CMTime {
        guard let start = pauseStart else { return .zero }
        pauseStart = nil
        let end = time > start ? time : start
        resumeTime = end
        guard let sessionStart, start >= sessionStart, end > start else { return .zero }
        let length = end - start
        pauseOffset = pauseOffset + length
        pauses.append(start.seconds...end.seconds)
        return length
    }

    /// Where a sample with host `pts` (and `duration`, for audio) goes:
    /// its retimed PTS, or `nil` when it falls inside a pause.
    func outputTime(forHostTime pts: CMTime, duration: CMTime = .zero) -> CMTime? {
        guard pts.isValid else { return nil }
        if let resumeTime, pts < resumeTime { return nil }
        if let pauseStart {
            let end = duration.isValid && duration > .zero ? pts + duration : pts
            if pts >= pauseStart || end > pauseStart { return nil }
        }
        return pts - pauseOffset
    }

    /// Media-side time of a host instant (stop time, live duration): an open
    /// pause freezes it at the pause start.
    func outputTime(forStopTime time: CMTime) -> CMTime {
        let effective = pauseStart.map { $0 < time ? $0 : time } ?? time
        return effective - pauseOffset
    }

    /// Pauses including the open one closed at `time` (host seconds), for
    /// metadata written while paused.
    func pauses(closingOpenPauseAt time: CMTime, sessionStart: CMTime?) -> [ClosedRange<Double>] {
        guard let start = pauseStart, let sessionStart, start >= sessionStart, time > start else { return pauses }
        return pauses + [start.seconds...time.seconds]
    }

    // MARK: Buffers

    /// A copy of `sampleBuffer` with every PTS/DTS moved back by `offset`.
    /// Returns the buffer itself for a zero offset; `nil` on CoreMedia errors.
    static func retimed(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard offset != .zero else { return sampleBuffer }
        return copy(sampleBuffer) { timing in
            if timing.presentationTimeStamp.isValid { timing.presentationTimeStamp = timing.presentationTimeStamp - offset }
            if timing.decodeTimeStamp.isValid { timing.decodeTimeStamp = timing.decodeTimeStamp - offset }
        }
    }

    /// A copy of a single-frame video buffer stamped at `pts` (DTS cleared):
    /// the last screen frame re-appended at the resume instant.
    static func restamped(_ sampleBuffer: CMSampleBuffer, at pts: CMTime) -> CMSampleBuffer? {
        copy(sampleBuffer) { timing in
            timing.presentationTimeStamp = pts
            timing.decodeTimeStamp = .invalid
        }
    }

    private static func copy(_ sampleBuffer: CMSampleBuffer, adjust: (inout CMSampleTimingInfo) -> Void) -> CMSampleBuffer? {
        var count: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count) == noErr,
              count > 0
        else { return nil }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count) == noErr else {
            return nil
        }
        for index in timings.indices { adjust(&timings[index]) }
        var result: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: count,
            sampleTimingArray: &timings,
            sampleBufferOut: &result
        )
        guard status == noErr else { return nil }
        return result
    }
}
