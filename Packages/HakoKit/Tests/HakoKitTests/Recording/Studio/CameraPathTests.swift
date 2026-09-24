import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("CameraPath")
struct CameraPathTests {
    /// 2000 × 1200 px source, 1000 × 600 pt recording.
    static let source = CGSize(width: 2000, height: 1200)
    static let points = CGSize(width: 1000, height: 600)
    static let full = CGRect(origin: .zero, size: source)

    static func path(_ segments: [ZoomSegment], speed: StudioZoomSpeed = .normal, cursor: CursorPath? = nil,
                     clicks: [RecordingClickEvent] = []) -> CameraPath {
        CameraPath(segments: segments, speed: speed, cursorPath: cursor, clicks: clicks, pointSize: points)
    }

    static func rect(_ p: CameraPath, _ t: Double) -> CGRect {
        p.viewRect(atSourceTime: t, sourceSize: source)
    }

    static func near(_ a: CGRect, _ b: CGRect, _ tol: Double = 1e-6) -> Bool {
        abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol
            && abs(a.height - b.height) < tol
    }

    static func inside(_ r: CGRect) -> Bool {
        r.minX >= -1e-9 && r.minY >= -1e-9 && r.maxX <= source.width + 1e-9 && r.maxY <= source.height + 1e-9
    }

    static func project(duration: Double = 10) -> StudioProject {
        StudioProject(source: StudioSource(pixelWidth: 2000, pixelHeight: 1200, pointWidth: 1000, pointHeight: 600,
                                           duration: duration))
    }

    static func metadata(clicks: [RecordingClickEvent]) -> RecordingMetadata {
        ZoomPlannerTests.metadata(clicks: clicks)
    }

    // MARK: Basics

    @Test func fullFrameOutsideSegments() {
        let p = Self.path([ZoomSegment(start: 2, end: 5, focus: .fixed(x: 0.3, y: 0.3))])
        for t in [-1.0, 0, 1.99, 5, 5.01, 9, .nan] {
            #expect(Self.rect(p, t) == Self.full)
            #expect(p.zoomScale(at: t.isNaN ? 0 : t) == 1)
        }
        #expect(Self.rect(Self.path([]), 3) == Self.full)
    }

    @Test func midSegmentTargetsFocus() {
        let centered = Self.path([ZoomSegment(start: 2, end: 6, scale: 2, focus: .fixed(x: 0.5, y: 0.5))])
        #expect(Self.near(Self.rect(centered, 4), CGRect(x: 500, y: 300, width: 1000, height: 600)))
        #expect(abs(centered.zoomScale(at: 4) - 2) < 1e-12)

        let off = Self.path([ZoomSegment(start: 2, end: 6, scale: 2, focus: .fixed(x: 0.3, y: 0.4))])
        let r = Self.rect(off, 4)
        #expect(Self.near(r, CGRect(x: 100, y: 180, width: 1000, height: 600)))
        #expect(abs(r.midX - 600) < 1e-6 && abs(r.midY - 480) < 1e-6)

        let four = Self.path([ZoomSegment(start: 2, end: 6, scale: 4, focus: .fixed(x: 0.5, y: 0.5))])
        #expect(Self.near(Self.rect(four, 4), CGRect(x: 750, y: 450, width: 500, height: 300)))
    }

    @Test func cornerFocusIsClampedWithoutOvershoot() {
        let p = Self.path([ZoomSegment(start: 1, end: 4, scale: 3, focus: .fixed(x: 0.02, y: 0.98))])
        // Held: pinned to the bottom-left corner.
        #expect(Self.near(Self.rect(p, 2.5), CGRect(x: 0, y: 800, width: 2000.0 / 3, height: 400)))
        var t = 0.0
        while t <= 5 {
            let r = Self.rect(p, t)
            #expect(Self.inside(r), "t = \(t): \(r)")
            #expect(abs(r.width / r.height - Self.source.width / Self.source.height) < 1e-9)
            t += 0.005
        }
    }

    @Test func leadInIsContinuousAndMonotonic() {
        let p = Self.path([ZoomSegment(start: 2, end: 6, scale: 2.5, focus: .fixed(x: 0.8, y: 0.2))])
        var previous = p.zoomScale(at: 2)
        #expect(previous == 1)
        var t = 2.0
        while t <= 2.5 {
            let z = p.zoomScale(at: t)
            #expect(z >= previous - 1e-12)
            #expect(z - previous < 0.05) // 1 ms steps: no jumps
            previous = z
            t += 0.001
        }
        #expect(abs(p.zoomScale(at: 2.5) - 2.5) < 1e-9)
        // Zoom-out mirrors it.
        previous = p.zoomScale(at: 5.5)
        t = 5.5
        while t < 6 {
            let z = p.zoomScale(at: t)
            #expect(z <= previous + 1e-12)
            previous = z
            t += 0.001
        }
        // Slow speed takes 0.8 s.
        let slow = Self.path([ZoomSegment(start: 2, end: 6)], speed: .slow)
        #expect(slow.zoomScale(at: 2.5) < 2)
        #expect(abs(slow.zoomScale(at: 2.85) - 2) < 1e-9)
    }

    @Test func shortSegmentSplitsTransitions() {
        // 0.6 s segment: in over 0.3 s, out over 0.3 s, peak at the middle.
        let p = Self.path([ZoomSegment(start: 1, end: 1.6, scale: 2, focus: .fixed(x: 0.5, y: 0.5))])
        #expect(abs(p.zoomScale(at: 1.3) - 2) < 1e-9)
        #expect(p.zoomScale(at: 1.15) > 1 && p.zoomScale(at: 1.15) < 2)
        #expect(p.zoomScale(at: 1.6) == 1)
    }

    @Test func closeSegmentsPanDirectly() {
        let a = ZoomSegment(start: 2, end: 4, scale: 2, focus: .fixed(x: 0.25, y: 0.25))
        let b = ZoomSegment(start: 4.5, end: 7, scale: 3, focus: .fixed(x: 0.75, y: 0.75))
        let p = Self.path([b, a])
        var t = 3.0
        var previousZ = p.zoomScale(at: t)
        while t <= 5.5 {
            let z = p.zoomScale(at: t)
            #expect(z >= 2 - 1e-9) // never zooms out between them
            #expect(z >= previousZ - 1e-12)
            #expect(Self.inside(Self.rect(p, t)))
            previousZ = z
            t += 0.01
        }
        #expect(Self.rect(p, 3).midX < 1000)
        #expect(Self.rect(p, 6).midX > 1000)

        // Far apart: back to the full frame in between.
        let far = Self.path([a, ZoomSegment(start: 7, end: 9, focus: .fixed(x: 0.75, y: 0.75))])
        #expect(Self.rect(far, 5.5) == Self.full)
    }

    @Test func overlappingSegmentsAreCleaned() {
        let p = Self.path([ZoomSegment(start: 2, end: 5), ZoomSegment(start: 3, end: 4),
                           ZoomSegment(start: 4, end: 6), ZoomSegment(start: 7, end: 7)])
        #expect(p.segments.count == 2)
        #expect(p.segments[1].start == 5)
    }

    // MARK: Follow cursor

    @Test func followsStillCursor() {
        let samples = (0...600).map { CursorSample(time: Double($0) / 60, x: 700, y: 400) }
        let cursor = CursorPath(samples: samples, smoothing: 0.6)
        let p = Self.path([ZoomSegment(start: 2, end: 6, scale: 2)], cursor: cursor)
        // Center (1400, 800) px fits: view 1000 × 600.
        let r = Self.rect(p, 4)
        #expect(abs(r.midX - 1400) < 1e-6 && abs(r.midY - 800) < 1e-6)
    }

    @Test func deadZoneIgnoresJitter() {
        // ±10 pt wobble around (500, 300): inside the 60 % dead zone (±150 × ±90 pt).
        let samples = (0...600).map { i in
            CursorSample(time: Double(i) / 60, x: Float(500 + 10 * sin(Double(i))), y: Float(300 + 10 * cos(Double(i))))
        }
        let p = Self.path([ZoomSegment(start: 2, end: 6, scale: 2)], cursor: CursorPath(samples: samples, smoothing: 0))
        let reference = Self.rect(p, 3)
        var t = 2.6
        while t < 5.4 {
            #expect(Self.near(Self.rect(p, t), reference, 1e-9))
            t += 0.05
        }
    }

    @Test func followMovesSmoothlyAndStaysInside() {
        // Cursor sweeps left → right and into the corner.
        let samples = (0...600).map { i -> CursorSample in
            let t = Double(i) / 60
            return CursorSample(time: t, x: Float(min(1000, 100 * t)), y: Float(min(600, 60 * t)))
        }
        let p = Self.path([ZoomSegment(start: 1, end: 9.5, scale: 2)], cursor: CursorPath(samples: samples, smoothing: 0.6))
        var t = 0.0
        var previous = Self.rect(p, 0)
        while t <= 10 {
            let r = Self.rect(p, t)
            #expect(Self.inside(r))
            // 5 ms steps: small moves only (no jumps / jitter).
            #expect(abs(r.midX - previous.midX) < 40 && abs(r.midY - previous.midY) < 40)
            previous = r
            t += 0.005
        }
        // Late in the segment the camera has followed toward the bottom right.
        let late = Self.rect(p, 9)
        #expect(late.midX > 1300 && late.midY > 700)
    }

    @Test func deterministic() {
        let samples = (0...300).map { CursorSample(time: Double($0) / 30, x: Float($0), y: Float($0) / 2) }
        let make = { Self.path([ZoomSegment(start: 1, end: 8)], cursor: CursorPath(samples: samples, smoothing: 0.5)) }
        let a = make(), b = make()
        for t in stride(from: 0.0, through: 9, by: 0.37) {
            #expect(Self.rect(a, t) == Self.rect(b, t))
            #expect(Self.rect(a, t) == Self.rect(a, t))
        }
    }

    // MARK: Plan §6 R7 acceptance (pure form)

    @Test func clickInTopLeftQuadrantZoomsThere() {
        let click = RecordingClickEvent(time: 3, x: 200, y: 150)
        let metadata = Self.metadata(clicks: [click])
        var project = Self.project()
        project.zoom.segments = ZoomPlanner.regenerated(project: project, metadata: metadata)
        #expect(project.zoom.segments.count == 1)

        // Without a cursor track (follows the click) and with one.
        let still = (0...600).map { CursorSample(time: Double($0) / 60, x: 200, y: 150) }
        for cursor in [nil, CursorPath(samples: still, clicks: [click], smoothing: 0.6)] {
            let camera = CameraPath(project: project, metadata: metadata, cursorPath: cursor)
            let zoomed = camera.viewRect(atSourceTime: 3.5, sourceSize: Self.source)
            #expect(zoomed.midX < Self.source.width / 2 && zoomed.midY < Self.source.height / 2)
            #expect(abs(camera.zoomScale(at: 3.5) - 2) < 1e-9)
            #expect(camera.viewRect(atSourceTime: 0, sourceSize: Self.source) == Self.full)

            let state = StudioFrameState.make(project: project, metadata: metadata, cursorPath: cursor,
                                              outputTime: 3.5, viewport: camera)
            #expect(state.viewRect == zoomed)
            #expect(abs(state.zoomScale - 2) < 1e-9)
            let start = StudioFrameState.makeWithCamera(project: project, metadata: metadata, cursorPath: cursor,
                                                        outputTime: 0)
            #expect(start.viewRect == Self.full)
            #expect(start.zoomScale == 1)
        }
    }
}
