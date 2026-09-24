import CoreGraphics
import Testing
@testable import HakoKit

@Suite("HostTime")
struct HostTimeTests {
    @Test func appleSilicon24MHzTimebase() {
        let tb = HostTimebase.appleSilicon24MHz
        #expect(tb.ticksPerSecond == 24_000_000)
        // 24 000 000 ticks = 1 s; 3 ticks = 125 ns.
        #expect(tb.seconds(fromTicks: 24_000_000) == 1)
        #expect(tb.nanoseconds(fromTicks: 3) == 125)
        #expect(tb.ticks(fromSeconds: 1) == 24_000_000)
        #expect(tb.ticks(fromSeconds: 0.5) == 12_000_000)
        // 1 hour of uptime.
        #expect(tb.seconds(fromTicks: 86_400_000_000) == 3600)
        // Ticks are NOT nanoseconds here.
        #expect(tb.nanoseconds(fromTicks: 1_000) != 1_000)
        #expect(tb.nanoseconds(fromTicks: 1_000) == 41_666)
    }

    @Test func nanosecondTimebase() {
        let tb = HostTimebase.nanoseconds
        #expect(tb.ticksPerSecond == 1e9)
        #expect(tb.seconds(fromTicks: 1_500_000_000) == 1.5)
        #expect(tb.ticks(fromSeconds: 2.25) == 2_250_000_000)
    }

    @Test func roundTripKeepsSubMillisecondPrecision() {
        let tb = HostTimebase.appleSilicon24MHz
        // ~30 days of uptime.
        let seconds = 2_592_000.123456
        let ticks = tb.ticks(fromSeconds: seconds)
        #expect(abs(tb.seconds(fromTicks: ticks) - seconds) < 1e-6)
    }

    @Test func edgeCases() {
        let tb = HostTimebase.appleSilicon24MHz
        #expect(tb.ticks(fromSeconds: -1) == 0)
        #expect(tb.ticks(fromSeconds: .nan) == 0)
        #expect(tb.nanoseconds(fromTicks: .max) == .max)
        #expect(HostTimebase(numer: 1, denom: 0).denom == 1)
    }

    @Test func eventTimestampConversions() {
        let tb = HostTimebase.appleSilicon24MHz
        #expect(HostTime.seconds(fromCGEventTimestamp: 48_000_000, timebase: tb) == 2)
        #expect(HostTime.seconds(fromMachTicks: 36_000_000, timebase: tb) == 1.5)
        #expect(HostTime.machTicks(fromSeconds: 1.5, timebase: tb) == 36_000_000)
        #expect(HostTime.seconds(fromNSEventTimestamp: 1234.5) == 1234.5)
    }

    @Test func currentClockIsMonotonicAndConsistent() {
        let a = HostTime.nowSeconds()
        let ticks = HostTime.nowTicks()
        let b = HostTime.nowSeconds()
        #expect(b >= a)
        let mid = HostTime.seconds(fromMachTicks: ticks)
        #expect(mid >= a && mid <= b)
        #expect(HostTimebase.current.ticksPerSecond > 0)
    }
}

@Suite("RecordingTimeline")
struct RecordingTimelineTests {
    @Test func noPausesIsOffsetFromOrigin() {
        let t = RecordingTimeline(origin: 100)
        #expect(t.mediaTime(host: 100) == 0)
        #expect(t.mediaTime(host: 103.5) == 3.5)
        #expect(t.mediaTime(host: 99.9) == nil)
        #expect(t.mediaDuration(stoppedAt: 106) == 6)
        #expect(t.hostTime(media: 2) == 102)
    }

    @Test func pausesAreRemovedFromMediaTime() {
        // Record 3 s, pause 2 s, record 3 s (R1 acceptance 1: 6 s).
        let t = RecordingTimeline(origin: 100, pauses: [103...105])
        #expect(t.mediaTime(host: 102) == 2)
        #expect(t.mediaTime(host: 103) == nil) // pause start: dropped
        #expect(t.mediaTime(host: 104) == nil)
        #expect(t.mediaTime(host: 105) == 3) // resume instant
        #expect(t.mediaTime(host: 107) == 5)
        #expect(t.mediaDuration(stoppedAt: 108) == 6)
        #expect(t.pausedDuration(before: 104) == 1)
        #expect(t.pausedDuration(before: 200) == 2)
        #expect(t.hostTime(media: 2) == 102)
        #expect(t.hostTime(media: 3) == 105)
        #expect(t.hostTime(media: 5) == 107)
    }

    @Test func multiplePausesAndInverse() {
        let t = RecordingTimeline(origin: 10, pauses: [20...25, 12...13])
        #expect(t.pauses == [12...13, 20...25])
        #expect(t.mediaTime(host: 12.5) == nil)
        #expect(t.mediaTime(host: 15) == 4)
        #expect(t.mediaTime(host: 30) == 14)
        for media in stride(from: 0.0, through: 20.0, by: 0.5) {
            let host = t.hostTime(media: media)
            #expect(t.mediaTime(host: host) == media)
        }
    }

    @Test func pausesMergeAndClipToOrigin() {
        let t = RecordingTimeline(origin: 10, pauses: [5...12, 11...14, 20...21, 21...22])
        #expect(t.pauses == [5...14, 20...22])
        // Only 10...14 counts (4 s), plus 2 s.
        #expect(t.pausedDuration(before: 30) == 6)
        #expect(t.mediaTime(host: 14) == 0)
        #expect(t.mediaTime(host: 30) == 14)
        #expect(t.hostTime(media: 0) == 14)
    }

    @Test func liveBeginAndEndPause() {
        var t = RecordingTimeline(origin: 0)
        t.beginPause(at: 3)
        #expect(t.isPaused)
        #expect(t.mediaTime(host: 4) == nil)
        #expect(t.pausedDuration(before: 4) == 1)
        t.beginPause(at: 3.5) // no-op
        t.endPause(at: 5)
        #expect(!t.isPaused)
        #expect(t.pauses == [3...5])
        t.endPause(at: 9) // no-op
        #expect(t.pauses == [3...5])
        #expect(t.mediaTime(host: 6) == 4)
        // Zero-length pause is ignored.
        t.beginPause(at: 7)
        t.endPause(at: 7)
        #expect(t.pauses == [3...5])
    }

    @Test func metadataBuildsTimeline() {
        let meta = RecordingMetadata(
            hostTimeOrigin: 50,
            pauses: [52...53],
            geometry: RecordingGeometryInfo(rect: .zero, displayID: 1, scale: 2, pixelWidth: 2, pixelHeight: 2),
            cursorBakedIn: true
        )
        #expect(meta.timeline.mediaTime(host: 54) == 3)
    }
}
