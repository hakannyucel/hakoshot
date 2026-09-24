import CoreGraphics
import Foundation

/// Temporal sub-sampling for Studio motion blur (plan §4.19).
///
/// The shutter is open for `frameDuration × shutterAngle / 360 × intensity`
/// seconds, centered on the frame's source time (kept inside its edit
/// segment, so it never straddles a cut). How far the picture moves on the
/// canvas while it is open (camera zoom / pan and cursor) decides the
/// sample count: `N = clamp(ceil(displacement / pixelsPerSample), 1, maxSamples)`.
/// No motion → `N = 1` at the frame time (no extra cost). Samples sit at
/// the centers of `N` equal slices of the shutter, with equal weights that
/// sum to 1. The renderer draws the same source frame once per sample with
/// that time's camera and cursor, and averages.
public struct MotionBlurPlan: Sendable, Hashable {
    public struct Parameters: Sendable, Hashable {
        /// Shutter angle at intensity 1, degrees (180° = half the frame).
        public var shutterAngle: Double
        /// One sample per this many canvas pixels of movement.
        public var pixelsPerSample: Double
        public var maxSamples: Int
        /// Sub-slices used to measure movement over the shutter.
        public var measureSteps: Int

        public init(shutterAngle: Double = 180, pixelsPerSample: Double = 4, maxSamples: Int = 8, measureSteps: Int = 4) {
            self.shutterAngle = shutterAngle
            self.pixelsPerSample = pixelsPerSample
            self.maxSamples = maxSamples
            self.measureSteps = measureSteps
        }

        /// Export quality.
        public static let standard = Parameters()
        /// Preview while playing (plan: N ≤ 2).
        public static let preview = Parameters(maxSamples: 2)
    }

    public struct Sample: Sendable, Hashable {
        /// Source time to evaluate the camera and cursor at.
        public var sourceTime: Double
        public var weight: Double

        public init(sourceTime: Double, weight: Double) {
            self.sourceTime = sourceTime
            self.weight = weight
        }
    }

    /// The frame's source time.
    public let sourceTime: Double
    /// Open shutter length actually used, seconds (0 = no blur).
    public let shutterDuration: Double
    /// Canvas pixels the picture moves while the shutter is open.
    public let displacement: Double
    /// At least one; weights sum to 1.
    public let samples: [Sample]

    public var count: Int { samples.count }
    public var isBlurred: Bool { samples.count > 1 }

    /// One sample at `sourceTime` (no blur).
    public static func single(sourceTime: Double, displacement: Double = 0) -> MotionBlurPlan {
        MotionBlurPlan(sourceTime: sourceTime, shutterDuration: 0, displacement: displacement,
                       samples: [Sample(sourceTime: sourceTime, weight: 1)])
    }

    // MARK: Core

    /// - Parameters:
    ///   - frameDuration: output frame interval, seconds (`1 / fps`).
    ///   - intensity: `0…1` (clamped); 0 = no blur.
    ///   - bounds: source range the shutter must stay in (the edit segment).
    ///   - displacement: canvas pixels moved between two source times.
    public static func make(
        sourceTime: Double,
        frameDuration: Double,
        intensity: Double,
        bounds: ClosedRange<Double>? = nil,
        parameters: Parameters = .standard,
        displacement: (Double, Double) -> Double
    ) -> MotionBlurPlan {
        let k = clampFinite(intensity, 0, 1, fallback: 0)
        let exposure = frameDuration * clampFinite(parameters.shutterAngle, 0, 360, fallback: 180) / 360 * k
        guard sourceTime.isFinite, exposure.isFinite, exposure > 0, parameters.maxSamples > 1 else {
            return .single(sourceTime: sourceTime)
        }
        var lo = sourceTime - exposure / 2, hi = sourceTime + exposure / 2
        if let bounds {
            lo = max(lo, bounds.lowerBound)
            hi = min(hi, bounds.upperBound)
        }
        guard hi > lo else { return .single(sourceTime: sourceTime) }

        let steps = max(parameters.measureSteps, 1)
        var moved = 0.0
        var previous = lo
        for s in 1...steps {
            let t = lo + (hi - lo) * Double(s) / Double(steps)
            let d = displacement(previous, t)
            if d.isFinite { moved += max(d, 0) }
            previous = t
        }

        let perSample = parameters.pixelsPerSample > 0 ? parameters.pixelsPerSample : 4
        let wanted = (moved / perSample).rounded(.up)
        let n = wanted.isFinite ? min(max(Int(wanted), 1), parameters.maxSamples) : 1
        guard n > 1 else { return .single(sourceTime: sourceTime, displacement: moved) }

        let slice = (hi - lo) / Double(n)
        let weight = 1 / Double(n)
        let samples = (0..<n).map { i in Sample(sourceTime: lo + (Double(i) + 0.5) * slice, weight: weight) }
        return MotionBlurPlan(sourceTime: sourceTime, shutterDuration: hi - lo, displacement: moved, samples: samples)
    }

    // MARK: Project

    /// Plan for timeline time `outputTime` using the project's motion blur
    /// settings, output frame rate, canvas layout, `viewport` (usually a
    /// `CameraPath`) and the cursor.
    ///
    /// - Parameter fps: output frame rate; default the project's export rate.
    public static func make(
        project: StudioProject,
        metadata: RecordingMetadata?,
        cursorPath: CursorPath?,
        viewport: any StudioViewport,
        outputTime: Double,
        fps: Double? = nil,
        parameters: Parameters = .standard
    ) -> MotionBlurPlan {
        let timeline = project.timeline
        let sourceTime = timeline.sourceTime(forOutput: outputTime)
        guard project.motionBlur.enabled else { return .single(sourceTime: sourceTime) }
        let rate = fps ?? Double(project.export.outputFPS(sourceFPS: project.source.fps))
        guard rate > 0, rate.isFinite else { return .single(sourceTime: sourceTime) }

        let bounds = timeline.segments.first { $0.contains(sourceTime) || sourceTime == $0.end }
            .map { $0.start...$0.end }
        let measure = displacementMeasure(project: project, metadata: metadata, cursorPath: cursorPath, viewport: viewport)
        return make(sourceTime: sourceTime, frameDuration: 1 / rate, intensity: project.motionBlur.intensity,
                    bounds: bounds, parameters: parameters, displacement: measure)
    }

    /// Canvas pixels the picture moves between two source times: the largest
    /// of the view corners' movement (zoom / pan) and the cursor's.
    public static func displacementMeasure(
        project: StudioProject,
        metadata: RecordingMetadata?,
        cursorPath: CursorPath?,
        viewport: any StudioViewport
    ) -> @Sendable (Double, Double) -> Double {
        let sourceSize = project.source.pixelSize
        let canvasSize = project.canvasPixelSize
        let style = project.canvas.background
        let k = StudioCanvas.lengthScale(canvasHeight: canvasSize.height)
        let content = StudioFrameState.contentRect(canvasSize: canvasSize, sourceSize: sourceSize,
                                                   padding: max(style.padding, 0) * k, alignment: style.alignment)
        let ppp = metadata?.geometry.pixelsPerPoint ?? project.source.pixelsPerPoint
        let cursorDrawn = project.cursor.visible && project.supportsCursorEditing && !(metadata?.cursorBakedIn ?? false)
        let path = cursorDrawn ? cursorPath : nil

        return { t0, t1 in
            let v0 = viewport.viewRect(atSourceTime: t0, sourceSize: sourceSize)
            let v1 = viewport.viewRect(atSourceTime: t1, sourceSize: sourceSize)
            guard v0.width > 0, v1.width > 0 else { return 0 }
            let s0 = content.width / v0.width, s1 = content.width / v1.width
            func canvas(_ p: CGPoint, _ v: CGRect, _ s: Double) -> CGPoint {
                CGPoint(x: (p.x - v.minX) * s, y: (p.y - v.minY) * s)
            }
            var moved = 0.0
            for v in [v0, v1] {
                for p in [CGPoint(x: v.minX, y: v.minY), CGPoint(x: v.maxX, y: v.minY),
                          CGPoint(x: v.minX, y: v.maxY), CGPoint(x: v.maxX, y: v.maxY)] {
                    let a = canvas(p, v0, s0), b = canvas(p, v1, s1)
                    moved = max(moved, hypot(b.x - a.x, b.y - a.y))
                }
            }
            if let path, let p0 = path.position(at: t0), let p1 = path.position(at: t1) {
                let a = canvas(CGPoint(x: p0.x * ppp, y: p0.y * ppp), v0, s0)
                let b = canvas(CGPoint(x: p1.x * ppp, y: p1.y * ppp), v1, s1)
                moved = max(moved, hypot(b.x - a.x, b.y - a.y))
            }
            return moved
        }
    }
}
