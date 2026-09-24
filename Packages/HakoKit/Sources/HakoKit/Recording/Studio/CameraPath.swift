import CoreGraphics
import Foundation

/// Source time → visible source rect for the zoom segments (plan §4.20).
///
/// - Outside every segment: the whole frame.
/// - A segment zooms in over its first `transition` seconds (speed: slow /
///   normal / fast = 0.8 / 0.5 / 0.3 s, capped at half the segment) with its
///   easing, holds, then zooms out over its last `transition` seconds. The
///   scale is interpolated in log space (`scale^p`), so it is continuous and
///   monotonic during both ramps; the center moves from the frame center to
///   the focus with the same progress.
/// - Segments at most `directPanGap` apart form one block: the camera pans
///   and rescales from one to the next without zooming out in between.
/// - `.followCursor`: the smoothed cursor is followed with a dead zone (the
///   camera rests while the cursor stays in the inner `deadZoneFraction` of
///   the view) and a critically damped spring (ω = `springOmega`). The follow
///   track is precomputed on a fixed grid, so a time always gives the same
///   rect (preview and export agree). Without a cursor track the latest
///   click is followed instead.
/// - The rect is always clamped inside the source (no black edges, no
///   overshoot) and keeps the source aspect ratio.
///
/// Build it once per project edit (the compositor keeps it in its
/// instruction); `viewRect` is cheap.
public struct CameraPath: StudioViewport, Sendable {
    public struct Parameters: Sendable, Hashable {
        /// The camera rests while the cursor stays inside this fraction of
        /// the view (centered).
        public var deadZoneFraction: Double
        /// Critically damped spring angular frequency, rad/s.
        public var springOmega: Double
        /// Follow track grid rate, Hz.
        public var followSampleRate: Double
        /// Segments at most this far apart pan directly, seconds.
        public var directPanGap: Double

        public init(deadZoneFraction: Double = 0.6, springOmega: Double = 6, followSampleRate: Double = 60,
                    directPanGap: Double = 1.0) {
            self.deadZoneFraction = deadZoneFraction
            self.springOmega = springOmega
            self.followSampleRate = followSampleRate
            self.directPanGap = directPanGap
        }

        public static let standard = Parameters()
    }

    /// Cleaned segments: normalized, non-empty, sorted, non-overlapping.
    public let segments: [ZoomSegment]
    public let transitionDuration: Double
    public let parameters: Parameters
    private let blocks: [Block]

    // MARK: Init

    /// - Parameters:
    ///   - segments: zoom segments in source seconds (any order).
    ///   - cursorPath: smoothed cursor for `.followCursor` segments.
    ///   - clicks: fallback focus for `.followCursor` without a cursor track.
    ///   - pointSize: recording rect size in the points the cursor and clicks use.
    public init(
        segments: [ZoomSegment],
        speed: StudioZoomSpeed = .normal,
        cursorPath: CursorPath? = nil,
        clicks: [RecordingClickEvent] = [],
        pointSize: CGSize,
        parameters: Parameters = .standard
    ) {
        let cleaned = Self.clean(segments)
        self.segments = cleaned
        self.transitionDuration = speed.transitionDuration
        self.parameters = parameters

        let w = Double(pointSize.width), h = Double(pointSize.height)
        let downs = clicks.filter { $0.isDown && $0.time.isFinite }.sorted { $0.time < $1.time }
        let path = (cursorPath?.isEmpty ?? true) ? nil : cursorPath
        let focusAt: (Double) -> (Double, Double)? = { t in
            guard w > 0, h > 0 else { return nil }
            if let path, let p = path.position(at: t) {
                return (Double(p.x) / w, Double(p.y) / h)
            }
            guard let first = downs.first else { return nil }
            let c = downs.last(where: { $0.time <= t }) ?? first
            return (c.x / w, c.y / h)
        }

        // Group into blocks.
        var groups: [[ZoomSegment]] = []
        for segment in cleaned {
            if let last = groups.last?.last, segment.start - last.end <= parameters.directPanGap {
                groups[groups.count - 1].append(segment)
            } else {
                groups.append([segment])
            }
        }
        self.blocks = groups.map { Block(segments: $0, transition: speed.transitionDuration,
                                         parameters: parameters, focusAt: focusAt) }
    }

    /// The project's zoom segments and speed, following `cursorPath` (or the
    /// metadata clicks when there is none).
    public init(
        project: StudioProject,
        metadata: RecordingMetadata?,
        cursorPath: CursorPath?,
        parameters: Parameters = .standard
    ) {
        self.init(
            segments: project.zoom.segments,
            speed: project.zoom.speed,
            cursorPath: cursorPath,
            clicks: metadata?.clicks ?? [],
            pointSize: ZoomPlanner.pointSize(project: project, metadata: metadata),
            parameters: parameters
        )
    }

    // MARK: Query

    /// Zoom factor at source time `t` (1 = whole frame).
    public func zoomScale(at t: Double) -> Double {
        guard let block = block(at: t) else { return 1 }
        return block.scale(block.phase(at: t))
    }

    /// `true` while some zoom is applied.
    public func isZoomed(at t: Double) -> Bool { zoomScale(at: t) > 1 + 1e-9 }

    /// Visible rect in unit source coordinates (`0…1`, y down).
    public func unitViewRect(at t: Double) -> CGRect {
        guard let block = block(at: t) else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let phase = block.phase(at: t)
        let z = block.scale(phase)
        guard z > 1 + 1e-12 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let (cx, cy) = block.center(phase, at: t)
        let half = 0.5 / z
        let x = min(max(cx - half, 0), 1 - 2 * half)
        let y = min(max(cy - half, 0), 1 - 2 * half)
        return CGRect(x: x, y: y, width: 2 * half, height: 2 * half)
    }

    public func viewRect(atSourceTime t: Double, sourceSize: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: sourceSize)
        guard t.isFinite, sourceSize.width > 0, sourceSize.height > 0 else { return full }
        let u = unitViewRect(at: t)
        guard u.width < 1 else { return full }
        let width = u.width * sourceSize.width, height = u.height * sourceSize.height
        let x = min(max(u.minX * sourceSize.width, 0), sourceSize.width - width)
        let y = min(max(u.minY * sourceSize.height, 0), sourceSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func block(at t: Double) -> Block? {
        guard t.isFinite else { return nil }
        for block in blocks {
            if t < block.start { return nil }
            if t < block.end { return block }
        }
        return nil
    }

    static func clean(_ segments: [ZoomSegment]) -> [ZoomSegment] {
        let sorted = segments.map { $0.normalized() }
            .filter { $0.end - $0.start > 1e-6 }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var out: [ZoomSegment] = []
        for var s in sorted {
            if let last = out.last, s.start < last.end { s.start = last.end }
            if s.end - s.start > 1e-6 { out.append(s) }
        }
        return out
    }
}

// MARK: - Block

extension CameraPath {
    enum Phase {
        /// Progress 0…1 (eased) of the zoom-in to segment 0.
        case zoomIn(Double)
        case hold(Int)
        /// Eased weight 0…1 from segment `i` to `i + 1`.
        case transition(Int, Double)
        /// Remaining zoom 1…0 (eased) of the last segment.
        case zoomOut(Double)
    }

    /// Segments that pan into each other without zooming out.
    struct Block: Sendable {
        let segments: [ZoomSegment]
        let start: Double
        let end: Double
        let zoomInEnd: Double
        let zoomOutStart: Double
        /// Transition `i` (segment i → i+1) spans `transA[i] ..< transB[i]`.
        let transA: [Double]
        let transB: [Double]
        /// Follow track (unit coordinates) on a uniform grid from `start`.
        let followStep: Double
        let followX: [Double]
        let followY: [Double]

        init(segments: [ZoomSegment], transition: Double, parameters: Parameters,
             focusAt: (Double) -> (Double, Double)?) {
            self.segments = segments
            let first = segments[0], last = segments[segments.count - 1]
            let t = max(transition, 0)
            let blockStart = first.start, blockEnd = last.end
            let zIn = first.start + min(t, first.duration / 2)
            let zOut = last.end - min(t, last.duration / 2)
            var a: [Double] = [], b: [Double] = []
            for i in 0..<(segments.count - 1) {
                let s0 = segments[i], s1 = segments[i + 1]
                a.append(max(s0.end - t / 2, s0.start + s0.duration / 2))
                b.append(min(s1.start + t / 2, s1.start + s1.duration / 2))
            }
            start = blockStart
            end = blockEnd
            zoomInEnd = zIn
            zoomOutStart = zOut
            transA = a
            transB = b

            let rate = parameters.followSampleRate > 0 && parameters.followSampleRate.isFinite
                ? parameters.followSampleRate : 60
            let step = 1 / rate
            followStep = step
            var xs: [Double] = [], ys: [Double] = []
            if segments.contains(where: { $0.focus == .followCursor }), focusAt(zIn) != nil {
                (xs, ys) = Self.followTrack(
                    start: blockStart, end: blockEnd, zoomInEnd: zIn, step: step, parameters: parameters,
                    targetScale: { time in
                        Self.targetScale(segments: segments, transA: a, transB: b, zoomInEnd: zIn,
                                         zoomOutStart: zOut, start: blockStart, at: time)
                    },
                    focusAt: focusAt
                )
            }
            followX = xs
            followY = ys
        }

        // MARK: Phase

        func phase(at t: Double) -> Phase {
            Self.phase(segments: segments, transA: transA, transB: transB, zoomInEnd: zoomInEnd,
                       zoomOutStart: zoomOutStart, start: start, end: end, at: t)
        }

        static func phase(segments: [ZoomSegment], transA: [Double], transB: [Double], zoomInEnd: Double,
                          zoomOutStart: Double, start: Double, end: Double, at t: Double) -> Phase {
            let n = segments.count - 1
            if t < zoomInEnd {
                let f = zoomInEnd > start ? (t - start) / (zoomInEnd - start) : 1
                return .zoomIn(segments[0].easing.apply(f))
            }
            if t >= zoomOutStart {
                let f = end > zoomOutStart ? (t - zoomOutStart) / (end - zoomOutStart) : 1
                return .zoomOut(1 - segments[n].easing.apply(f))
            }
            for i in 0..<n {
                if t < transA[i] { return .hold(i) }
                if t < transB[i] {
                    let f = (t - transA[i]) / (transB[i] - transA[i])
                    return .transition(i, segments[i + 1].easing.apply(f))
                }
            }
            return .hold(n)
        }

        func scale(_ phase: Phase) -> Double {
            switch phase {
            case .zoomIn(let p): pow(segments[0].scale, p)
            case .zoomOut(let p): pow(segments[segments.count - 1].scale, p)
            case .hold(let i): segments[i].scale
            case .transition(let i, let w): exp(log(segments[i].scale) * (1 - w) + log(segments[i + 1].scale) * w)
            }
        }

        /// Target scale ignoring the zoom-in / zoom-out ramps (for the dead
        /// zone and follow clamping).
        static func targetScale(segments: [ZoomSegment], transA: [Double], transB: [Double], zoomInEnd: Double,
                                zoomOutStart: Double, start: Double, at t: Double) -> Double {
            let end = segments[segments.count - 1].end
            switch phase(segments: segments, transA: transA, transB: transB, zoomInEnd: zoomInEnd,
                         zoomOutStart: zoomOutStart, start: start, end: end, at: t) {
            case .zoomIn: return segments[0].scale
            case .zoomOut: return segments[segments.count - 1].scale
            case .hold(let i): return segments[i].scale
            case .transition(let i, let w):
                return exp(log(segments[i].scale) * (1 - w) + log(segments[i + 1].scale) * w)
            }
        }

        /// Unclamped view center (unit coordinates).
        func center(_ phase: Phase, at t: Double) -> (Double, Double) {
            switch phase {
            case .zoomIn(let p):
                let c = focus(0, at: t)
                return (0.5 + (c.0 - 0.5) * p, 0.5 + (c.1 - 0.5) * p)
            case .zoomOut(let p):
                let c = focus(segments.count - 1, at: t)
                return (0.5 + (c.0 - 0.5) * p, 0.5 + (c.1 - 0.5) * p)
            case .hold(let i):
                return focus(i, at: t)
            case .transition(let i, let w):
                let c0 = focus(i, at: t), c1 = focus(i + 1, at: t)
                return (c0.0 + (c1.0 - c0.0) * w, c0.1 + (c1.1 - c0.1) * w)
            }
        }

        /// Focus of segment `i` at `t`, unit coordinates.
        func focus(_ i: Int, at t: Double) -> (Double, Double) {
            switch segments[i].focus {
            case .fixed(let x, let y):
                return (x, y)
            case .followCursor:
                guard !followX.isEmpty else { return (0.5, 0.5) }
                let f = max(0, (t - start) / followStep)
                let k = min(Int(f), followX.count - 1)
                guard k + 1 < followX.count else { return (followX[k], followY[k]) }
                let r = min(f - Double(k), 1)
                return (followX[k] + (followX[k + 1] - followX[k]) * r,
                        followY[k] + (followY[k + 1] - followY[k]) * r)
            }
        }

        // MARK: Follow

        /// Dead zone + critically damped spring over the block, on a uniform
        /// grid. The camera starts where the cursor is when the zoom-in ends
        /// and stays there during the zoom-in.
        static func followTrack(
            start: Double, end: Double, zoomInEnd: Double, step: Double,
            parameters: Parameters,
            targetScale: (Double) -> Double,
            focusAt: (Double) -> (Double, Double)?
        ) -> ([Double], [Double]) {
            let g = (start: start, end: end, zoomInEnd: zoomInEnd, step: step)
            let count = Int(((g.end - g.start) / g.step).rounded(.up)) + 1
            let omega = max(parameters.springOmega, 0)
            let dz = min(max(parameters.deadZoneFraction, 0), 1) / 2

            func clampCenter(_ v: Double, _ z: Double) -> Double {
                let half = 0.5 / max(z, 1)
                return min(max(v, half), 1 - half)
            }

            let z0 = targetScale(g.zoomInEnd)
            let initial = focusAt(g.zoomInEnd) ?? (0.5, 0.5)
            var cx = clampCenter(initial.0, z0), cy = clampCenter(initial.1, z0)
            var tx = cx, ty = cy
            var vx = 0.0, vy = 0.0
            var xs = [Double](), ys = [Double]()
            xs.reserveCapacity(count)
            ys.reserveCapacity(count)
            var previous = g.start

            func springStep(_ x: inout Double, _ v: inout Double, target: Double, h: Double) {
                let y = x - target
                let e = exp(-omega * h)
                let c = v + omega * y
                let newY = (y + c * h) * e
                v = (v - omega * c * h) * e
                x = target + newY
            }

            for k in 0..<count {
                let t = min(g.start + Double(k) * g.step, g.end)
                if t > g.zoomInEnd, let p = focusAt(t) {
                    let z = max(targetScale(t), 1)
                    let d = dz / z
                    if p.0 > tx + d { tx = p.0 - d } else if p.0 < tx - d { tx = p.0 + d }
                    if p.1 > ty + d { ty = p.1 - d } else if p.1 < ty - d { ty = p.1 + d }
                    tx = clampCenter(tx, z)
                    ty = clampCenter(ty, z)
                    let h = t - max(previous, g.zoomInEnd)
                    if h > 0 {
                        springStep(&cx, &vx, target: tx, h: h)
                        springStep(&cy, &vy, target: ty, h: h)
                    }
                }
                previous = t
                xs.append(cx)
                ys.append(cy)
            }
            return (xs, ys)
        }
    }
}

// MARK: - StudioFrameState

extension StudioFrameState {
    /// State at timeline time `outputTime` with the project's zoom applied
    /// (builds a `CameraPath`). Per-frame callers (compositor) should build
    /// the `CameraPath` once and pass it as `viewport:` instead.
    public static func makeWithCamera(
        project: StudioProject,
        metadata: RecordingMetadata?,
        cursorPath: CursorPath?,
        outputTime: Double
    ) -> StudioFrameState {
        make(project: project, metadata: metadata, cursorPath: cursorPath, outputTime: outputTime,
             viewport: CameraPath(project: project, metadata: metadata, cursorPath: cursorPath))
    }
}
