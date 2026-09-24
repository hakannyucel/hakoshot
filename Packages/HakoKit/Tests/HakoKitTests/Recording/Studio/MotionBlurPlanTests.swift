import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("MotionBlurPlan")
struct MotionBlurPlanTests {
    static func project(intensity: Double = 1, enabled: Bool = true, segments: [ZoomSegment] = []) -> StudioProject {
        var p = CameraPathTests.project()
        p.motionBlur = StudioMotionBlur(enabled: enabled, intensity: intensity)
        p.zoom.segments = segments
        return p
    }

    static func weightSum(_ plan: MotionBlurPlan) -> Double { plan.samples.reduce(0) { $0 + $1.weight } }

    static let zoom = ZoomSegment(start: 1, end: 4, scale: 2, focus: .fixed(x: 0.5, y: 0.5))

    @Test func staticFrameIsSingleSample() {
        let p = Self.project()
        let still = CursorPath(samples: (0...600).map { CursorSample(time: Double($0) / 60, x: 300, y: 200) }, smoothing: 0.6)
        let camera = CameraPath(project: p, metadata: nil, cursorPath: still)
        let plan = MotionBlurPlan.make(project: p, metadata: nil, cursorPath: still, viewport: camera, outputTime: 2)
        #expect(plan.count == 1)
        #expect(!plan.isBlurred)
        #expect(plan.samples == [MotionBlurPlan.Sample(sourceTime: 2, weight: 1)])

        // Held zoom (no motion) is static too.
        let held = Self.project(segments: [Self.zoom])
        let heldPlan = MotionBlurPlan.make(project: held, metadata: nil, cursorPath: nil,
                                           viewport: CameraPath(project: held, metadata: nil, cursorPath: nil),
                                           outputTime: 2.5)
        #expect(heldPlan.count == 1)
    }

    @Test func zoomTransitionIsBlurred() {
        let p = Self.project(segments: [Self.zoom])
        let camera = CameraPath(project: p, metadata: nil, cursorPath: nil)
        let plan = MotionBlurPlan.make(project: p, metadata: nil, cursorPath: nil, viewport: camera, outputTime: 1.25, fps: 60)
        #expect(plan.count > 1)
        #expect(plan.count <= 8)
        #expect(abs(Self.weightSum(plan) - 1) < 1e-12)
        // 180° at 60 fps, intensity 1: 1/120 s centered on the frame.
        #expect(abs(plan.shutterDuration - 1.0 / 120) < 1e-12)
        let times = plan.samples.map(\.sourceTime)
        #expect(times == times.sorted())
        #expect(times.allSatisfy { abs($0 - 1.25) <= 1.0 / 240 + 1e-12 })
        #expect(abs(times.reduce(0, +) / Double(times.count) - 1.25) < 1e-12)

        // Preview cap.
        let preview = MotionBlurPlan.make(project: p, metadata: nil, cursorPath: nil, viewport: camera,
                                          outputTime: 1.25, fps: 60, parameters: .preview)
        #expect(preview.count == 2)
        #expect(abs(Self.weightSum(preview) - 1) < 1e-12)
    }

    @Test func intensityScalesShutter() {
        let camera = CameraPath(project: Self.project(segments: [Self.zoom]), metadata: nil, cursorPath: nil)
        let full = Self.project(intensity: 1, segments: [Self.zoom])
        let half = Self.project(intensity: 0.5, segments: [Self.zoom])
        let a = MotionBlurPlan.make(project: full, metadata: nil, cursorPath: nil, viewport: camera, outputTime: 1.25, fps: 60)
        let b = MotionBlurPlan.make(project: half, metadata: nil, cursorPath: nil, viewport: camera, outputTime: 1.25, fps: 60)
        #expect(abs(b.shutterDuration - a.shutterDuration / 2) < 1e-12)
        #expect(b.count <= a.count)
        #expect(b.displacement < a.displacement)
    }

    @Test func disabledOrZeroIntensityIsSingle() {
        for p in [Self.project(enabled: false, segments: [Self.zoom]), Self.project(intensity: 0, segments: [Self.zoom])] {
            let camera = CameraPath(project: p, metadata: nil, cursorPath: nil)
            let plan = MotionBlurPlan.make(project: p, metadata: nil, cursorPath: nil, viewport: camera, outputTime: 1.25)
            #expect(plan.count == 1)
            #expect(Self.weightSum(plan) == 1)
        }
    }

    @Test func movingCursorIsBlurred() {
        // 3000 pt/s sweep: fast enough for several samples without zoom.
        let fast = CursorPath(samples: (0...600).map { CursorSample(time: Double($0) / 60, x: Float($0 * 50 % 1000), y: 100) },
                              smoothing: 0)
        let p = Self.project()
        let plan = MotionBlurPlan.make(project: p, metadata: nil, cursorPath: fast, viewport: FullFrameViewport(),
                                       outputTime: 2.1, fps: 60)
        #expect(plan.count > 1)
        #expect(abs(Self.weightSum(plan) - 1) < 1e-12)
    }

    @Test func coreCountsAndCap() {
        // 1 px / ms: over 1/120 s ≈ 8.3 px → ceil(8.3 / 4) = 3 samples.
        let plan = MotionBlurPlan.make(sourceTime: 5, frameDuration: 1.0 / 60, intensity: 1) { t0, t1 in abs(t1 - t0) * 1000 }
        #expect(plan.count == 3)
        #expect(abs(Self.weightSum(plan) - 1) < 1e-12)
        // Huge motion → capped at 8.
        let capped = MotionBlurPlan.make(sourceTime: 5, frameDuration: 1.0 / 60, intensity: 1) { t0, t1 in abs(t1 - t0) * 1e6 }
        #expect(capped.count == 8)
        #expect(abs(Self.weightSum(capped) - 1) < 1e-12)
        // No motion → 1.
        let still = MotionBlurPlan.make(sourceTime: 5, frameDuration: 1.0 / 60, intensity: 1) { _, _ in 0 }
        #expect(still.count == 1)
        #expect(still.samples.first?.sourceTime == 5)
    }

    @Test func shutterStaysInsideEditSegment() {
        let plan = MotionBlurPlan.make(sourceTime: 5, frameDuration: 1.0 / 60, intensity: 1, bounds: 5...6) { t0, t1 in
            abs(t1 - t0) * 1e6
        }
        #expect(plan.samples.allSatisfy { $0.sourceTime >= 5 })
        #expect(abs(plan.shutterDuration - 1.0 / 240) < 1e-12)
    }
}
