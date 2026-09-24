import Testing
import CoreGraphics
@testable import HakoKit

@Suite("SnapEngine")
struct SnapEngineTests {
    let display = GlobalRect(x: 0, y: 0, width: 1000, height: 800)
    let window = GlobalRect(x: 200, y: 100, width: 400, height: 300)   // edges x 200/600, y 100/400

    var engine: SnapEngine { SnapEngine(windowFrames: [window], displayFrames: [display]) }

    @Test func defaultThresholdIsPlanValue() {
        #expect(SnapEngine.defaultThreshold == 6)
        #expect(engine.threshold == 6)
    }

    @Test func pointNearWindowEdgeSnaps() {
        #expect(engine.snap(CGPoint(x: 204, y: 250)) == CGPoint(x: 200, y: 250))
        #expect(engine.snap(CGPoint(x: 300, y: 395)) == CGPoint(x: 300, y: 400))
    }

    @Test func pointBeyondThresholdDoesNotSnap() {
        #expect(engine.snap(CGPoint(x: 207, y: 250)) == CGPoint(x: 207, y: 250))
    }

    @Test func exactlyAtThresholdSnaps() {
        #expect(engine.snap(CGPoint(x: 606, y: 250)).x == 600)
    }

    @Test func cornerSnapsBothAxes() {
        #expect(engine.snap(CGPoint(x: 597, y: 103)) == CGPoint(x: 600, y: 100))
    }

    @Test func windowEdgeIgnoredOutsideItsSpan() {
        // Far above the window: its left edge (x 200) must not attract.
        #expect(engine.snap(CGPoint(x: 203, y: 20)).x == 203)
        // Just above it (within threshold of the top edge): still attracts.
        #expect(engine.snap(CGPoint(x: 203, y: 96)) == CGPoint(x: 200, y: 100))
    }

    @Test func displayEdgesAlwaysSnap() {
        #expect(engine.snap(CGPoint(x: 3, y: 795)) == CGPoint(x: 0, y: 800))
        #expect(engine.snap(CGPoint(x: 996, y: 700)).x == 1000)
    }

    @Test func nearestEdgeWins() {
        let e = SnapEngine(windowFrames: [window, GlobalRect(x: 205, y: 100, width: 100, height: 100)], displayFrames: [])
        #expect(e.snap(CGPoint(x: 204, y: 150)).x == 205)
        #expect(e.snap(CGPoint(x: 201, y: 150)).x == 200)
    }

    @Test func disabledNeverSnaps() {
        #expect(SnapEngine.disabled.snap(CGPoint(x: 1, y: 1)) == CGPoint(x: 1, y: 1))
        let zero = SnapEngine(windowFrames: [window], displayFrames: [display], threshold: 0)
        #expect(zero.snap(CGPoint(x: 201, y: 250)).x == 201)
    }

    @Test func snapEdgesMovesOnlyListedEdges() {
        let rect = GlobalRect(x: 197, y: 50, width: 400, height: 348)  // minX 197, maxX 597, maxY 398
        let snapped = engine.snapEdges([.maxX, .maxY], of: rect)
        #expect(snapped == GlobalRect(x: 197, y: 50, width: 403, height: 350))
        let left = engine.snapEdges(.minX, of: rect)
        #expect(left.minX == 200 && left.maxX == 597)
    }

    @Test func snapEdgesNeverInverts() {
        let e = SnapEngine(windowFrames: [], displayFrames: [GlobalRect(x: 0, y: 0, width: 10, height: 10)], threshold: 6)
        let tiny = GlobalRect(x: 4, y: 4, width: 2, height: 2)
        // minX → 0 and maxX → 10 would be fine; force a crossing via a single far edge.
        #expect(e.snapEdges(.all, of: tiny).width > 0)
    }

    @Test func translationSnapsClosestEdgeAndKeepsSize() {
        let moving = GlobalRect(x: 603, y: 150, width: 100, height: 50)   // minX 603 → 600
        let snapped = engine.snapTranslation(of: moving)
        #expect(snapped == GlobalRect(x: 600, y: 150, width: 100, height: 50))
        let both = engine.snapTranslation(of: GlobalRect(x: 98, y: 395, width: 100, height: 50))  // maxX 198 → 200, minY 395 → 400
        #expect(both == GlobalRect(x: 100, y: 400, width: 100, height: 50))
    }

    @Test func translationPrefersSmallerCorrection() {
        // minX 202 (→200, -2) vs maxX 596 (→600, +4): -2 wins.
        let r = engine.snapTranslation(of: GlobalRect(x: 202, y: 150, width: 394, height: 50))
        #expect(r.minX == 200 && r.width == 394)
    }

    @Test func degenerateWindowsAreIgnored() {
        let e = SnapEngine(windowFrames: [GlobalRect(x: 50, y: 50, width: 0, height: 10)], displayFrames: [])
        #expect(e.verticalEdges.isEmpty)
    }
}
