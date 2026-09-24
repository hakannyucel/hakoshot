import Testing
@testable import HakoKit

@Suite("EditTimeline")
struct EditTimelineTests {
    private func approx(_ a: Double?, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a - b) <= tolerance
    }

    @Test func fullTimelineIsIdentity() {
        let t = EditTimeline(sourceDuration: 10)
        #expect(t.isIdentity)
        #expect(t.outputDuration == 10)
        #expect(t.segments == [EditTimeRange(start: 0, end: 10)])
        #expect(t.outputTime(forSource: 4.5) == 4.5)
        #expect(t.sourceTime(forOutput: 4.5) == 4.5)
        #expect(t.outputTime(forSource: 10) == 10)
    }

    @Test func trimMapsTimes() {
        // R3 acceptance: 10 s source trimmed to 2–7 → 5 s.
        let t = EditTimeline(sourceDuration: 10, trim: EditTimeRange(start: 2, end: 7))
        #expect(!t.isIdentity)
        #expect(t.outputDuration == 5)
        #expect(t.outputTime(forSource: 1.9) == nil)
        #expect(t.outputTime(forSource: 2) == 0)
        #expect(approx(t.outputTime(forSource: 6.5), 4.5))
        #expect(t.outputTime(forSource: 7) == 5)
        #expect(t.outputTime(forSource: 7.1) == nil)
        #expect(t.sourceTime(forOutput: 0) == 2)
        #expect(t.sourceTime(forOutput: 3) == 5)
        #expect(t.sourceTime(forOutput: 99) == 7)
        #expect(t.sourceTime(forOutput: -1) == 2)
        #expect(t.frameCount(fps: 30) == 150)
    }

    @Test func cutsAreRemovedAndMerged() {
        let t = EditTimeline(
            sourceDuration: 10,
            trim: EditTimeRange(start: 1, end: 9),
            cuts: [
                EditTimeRange(start: 5, end: 6),
                EditTimeRange(start: 3, end: 4),
                EditTimeRange(start: 3.5, end: 4.5), // overlaps → merged
                EditTimeRange(start: 0, end: 1.5), // clipped to trim
                EditTimeRange(start: 8, end: 8), // empty → dropped
            ]
        )
        #expect(t.cuts == [
            EditTimeRange(start: 1, end: 1.5),
            EditTimeRange(start: 3, end: 4.5),
            EditTimeRange(start: 5, end: 6),
        ])
        #expect(t.segments == [
            EditTimeRange(start: 1.5, end: 3),
            EditTimeRange(start: 4.5, end: 5),
            EditTimeRange(start: 6, end: 9),
        ])
        #expect(t.outputDuration == 5)
        // Source → output.
        #expect(t.outputTime(forSource: 1.2) == nil)
        #expect(t.outputTime(forSource: 1.5) == 0)
        #expect(t.outputTime(forSource: 4) == nil)
        #expect(t.outputTime(forSource: 4.5) == 1.5)
        #expect(t.outputTime(forSource: 5.5) == nil)
        #expect(t.outputTime(forSource: 6) == 2)
        #expect(t.outputTime(forSource: 9) == 5)
        // Output → source; a join maps to the later segment.
        #expect(t.sourceTime(forOutput: 1) == 2.5)
        #expect(t.sourceTime(forOutput: 1.5) == 4.5)
        #expect(t.sourceTime(forOutput: 2) == 6)
        #expect(t.sourceTime(forOutput: 4) == 8)
        // Round trip inside kept segments.
        for output in stride(from: 0.0, to: 5.0, by: 0.25) {
            #expect(approx(t.outputTime(forSource: t.sourceTime(forOutput: output)), output))
        }
    }

    @Test func trimIsClamped() {
        let t = EditTimeline(sourceDuration: 4, trim: EditTimeRange(start: -3, end: 12))
        #expect(t.trim == EditTimeRange(start: 0, end: 4))
        #expect(t.isIdentity)
        let inverted = EditTimeline(sourceDuration: 4, trim: EditTimeRange(start: 3, end: 1))
        #expect(inverted.outputDuration == 0)
        #expect(inverted.segments.isEmpty)
        #expect(inverted.sourceTime(forOutput: 1) == 3)
        #expect(EditTimeline(sourceDuration: .nan).outputDuration == 0)
    }

    @Test func frameSnapping() {
        #expect(EditTimeline.snap(2.01, fps: 30) == 2)
        #expect(abs(EditTimeline.snap(2.02, fps: 30) - 61.0 / 30) < 1e-12)
        #expect(EditTimeline.snap(1.26, fps: 4) == 1.25)
        #expect(EditTimeline.snap(1.3, fps: 0) == 1.3)
        #expect(EditTimeline.frameIndex(at: 2, fps: 30) == 60)
        #expect(EditTimeline.frameIndex(at: 2.03, fps: 30) == 60)
        #expect(EditTimeline.frameIndex(at: 1.0 / 3, fps: 30) == 10)

        let t = EditTimeline(
            sourceDuration: 10,
            trim: EditTimeRange(start: 2.013, end: 6.99),
            cuts: [EditTimeRange(start: 3.004, end: 3.51)]
        ).snapped(fps: 30)
        #expect(t.trim.start == 2)
        #expect(t.trim.end == 7)
        #expect(t.cuts.count == 1)
        #expect(abs(t.cuts[0].start - 3) < 1e-12)
        #expect(abs(t.cuts[0].end - 3.5) < 1e-12)
        #expect(t.frameCount(fps: 30) == 135) // 5 s − 0.5 s cut = 4.5 s
        // Every edge lands on the 30 fps grid.
        for edge in [t.trim.start, t.trim.end, t.cuts[0].start, t.cuts[0].end] {
            let frames = edge * 30
            #expect(abs(frames - frames.rounded()) < 1e-9)
        }
    }

    @Test func snappedEndStaysInsideSource() {
        let t = EditTimeline(sourceDuration: 3.99, trim: EditTimeRange(start: 0, end: 3.99)).snapped(fps: 1)
        #expect(t.trim.end == 3.99)
    }
}
