import CoreGraphics
import Foundation

/// Cursor path smoothing for Studio (plan §4.20).
///
/// 1. Raw samples are resampled onto a uniform grid (`sampleRate`), with
///    every mouse-down time inserted as an extra grid point.
/// 2. A 0.5 pt dead zone removes sub-point jitter.
/// 3. A critically damped spring runs forward, then backward over the
///    result: zero lag, no overshoot. `smoothing` 0…1 maps to τ = 0…120 ms,
///    the delay of one pass (ω = 2 / τ; exact per-step solution, so any step
///    length is stable).
/// 4. **Click pinning:** at each mouse-down the path is moved onto the click
///    point exactly; the correction fades out with a smoothstep over ±80 ms
///    (narrowed to half the gap to a neighbouring click, so pins never
///    disturb each other).
///
/// `smoothing == 0` returns the raw samples unchanged.
public enum CursorSmoothing {
    public struct Parameters: Sendable, Hashable {
        /// τ at `smoothing == 1`, seconds.
        public var maxTimeConstant: Double
        /// Half-width of the click pinning blend, seconds.
        public var clickPinWindow: Double
        /// Movement below this (points) is treated as jitter.
        public var deadZone: Double
        /// Grid rate of the smoothed path, Hz.
        public var sampleRate: Double

        public init(maxTimeConstant: Double = 0.12, clickPinWindow: Double = 0.08, deadZone: Double = 0.5, sampleRate: Double = 120) {
            self.maxTimeConstant = maxTimeConstant
            self.clickPinWindow = clickPinWindow
            self.deadZone = deadZone
            self.sampleRate = sampleRate
        }

        public static let standard = Parameters()
    }

    /// Spring time constant for `smoothing` (clamped to 0…1), seconds.
    public static func timeConstant(forSmoothing smoothing: Double, parameters: Parameters = .standard) -> Double {
        clampFinite(smoothing, 0, 1, fallback: 0) * parameters.maxTimeConstant
    }

    /// The smoothed path. Output samples carry the raw shape / flags in effect
    /// at their time.
    ///
    /// - Parameter clicks: only mouse-downs are pinned (ups are ignored).
    public static func smooth(
        _ samples: [CursorSample],
        clicks: [RecordingClickEvent] = [],
        smoothing: Double,
        parameters: Parameters = .standard
    ) -> [CursorSample] {
        let raw = sortedSamples(samples)
        let tau = timeConstant(forSmoothing: smoothing, parameters: parameters)
        guard tau > 0, raw.count >= 2, let first = raw.first, let last = raw.last, last.time > first.time else {
            return raw
        }
        let downs = clicks.filter { $0.isDown && $0.time >= first.time && $0.time <= last.time }
            .sorted { $0.time < $1.time }

        // 1. Grid (+ click times).
        let rate = parameters.sampleRate > 0 && parameters.sampleRate.isFinite ? parameters.sampleRate : 120
        let dt = 1 / rate
        var times: [Double] = []
        times.reserveCapacity(Int((last.time - first.time) * rate) + downs.count + 2)
        var i = 0
        while true {
            let t = first.time + Double(i) * dt
            if t >= last.time { break }
            times.append(t)
            i += 1
        }
        times.append(last.time)
        if !downs.isEmpty {
            times.append(contentsOf: downs.map(\.time))
            times.sort()
            var unique: [Double] = []
            unique.reserveCapacity(times.count)
            for t in times where unique.last.map({ t - $0 > 1e-9 }) ?? true {
                unique.append(t)
            }
            times = unique
        }

        // Resample (linear) + shapes / flags (step).
        var xs = [Double](repeating: 0, count: times.count)
        var ys = [Double](repeating: 0, count: times.count)
        var steps = [CursorSample](repeating: first, count: times.count)
        var j = 0
        for (k, t) in times.enumerated() {
            while j + 1 < raw.count, raw[j + 1].time <= t { j += 1 }
            let a = raw[j]
            steps[k] = a
            if j + 1 < raw.count, raw[j + 1].time > a.time, t > a.time {
                let b = raw[j + 1]
                let f = (t - a.time) / (b.time - a.time)
                xs[k] = Double(a.x) + (Double(b.x) - Double(a.x)) * f
                ys[k] = Double(a.y) + (Double(b.y) - Double(a.y)) * f
            } else {
                xs[k] = Double(a.x)
                ys[k] = Double(a.y)
            }
        }

        // 2. Dead zone.
        if parameters.deadZone > 0 {
            var hx = xs[0], hy = ys[0]
            for k in xs.indices {
                if hypot(xs[k] - hx, ys[k] - hy) >= parameters.deadZone {
                    hx = xs[k]
                    hy = ys[k]
                }
                xs[k] = hx
                ys[k] = hy
            }
        }

        // 3. Forward-backward critically damped spring.
        let omega = 2 / tau
        springFilter(&xs, times: times, omega: omega)
        springFilter(&ys, times: times, omega: omega)

        // 4. Click pinning.
        if !downs.isEmpty {
            pin(&xs, &ys, times: times, clicks: downs, window: max(parameters.clickPinWindow, 0))
        }

        var out: [CursorSample] = []
        out.reserveCapacity(times.count)
        for k in times.indices {
            out.append(CursorSample(time: times[k], x: Float(xs[k]), y: Float(ys[k]),
                                    shapeIndex: steps[k].shapeIndex, flags: steps[k].flags))
        }
        return out
    }

    // MARK: Internals

    static func sortedSamples(_ samples: [CursorSample]) -> [CursorSample] {
        let finite = samples.filter { $0.time.isFinite && $0.x.isFinite && $0.y.isFinite }
        var sorted = true
        for k in finite.indices.dropFirst() where finite[k].time < finite[k - 1].time {
            sorted = false
            break
        }
        if sorted { return finite }
        return finite.enumerated()
            .sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }
            .map(\.element)
    }

    /// Forward then backward pass of a critically damped spring following
    /// `values` (zero-order hold of the target per step).
    static func springFilter(_ values: inout [Double], times: [Double], omega: Double) {
        guard values.count >= 2 else { return }
        func pass(_ indices: [Int]) {
            var x = values[indices[0]]
            var v = 0.0
            for n in 1..<indices.count {
                let k = indices[n]
                let h = abs(times[k] - times[indices[n - 1]])
                let target = values[k]
                let y = x - target
                let e = exp(-omega * h)
                let c = v + omega * y
                let newY = (y + c * h) * e
                v = (v - omega * c * h) * e
                x = target + newY
                values[k] = x
            }
        }
        pass(Array(values.indices))
        pass(Array(values.indices.reversed()))
    }

    private static func pin(_ xs: inout [Double], _ ys: inout [Double], times: [Double],
                            clicks: [RecordingClickEvent], window: Double) {
        for (n, click) in clicks.enumerated() {
            guard let center = nearestIndex(times, click.time) else { continue }
            var w = window
            if n > 0 { w = min(w, (click.time - clicks[n - 1].time) / 2) }
            if n + 1 < clicks.count { w = min(w, (clicks[n + 1].time - click.time) / 2) }
            let ex = click.x - xs[center]
            let ey = click.y - ys[center]
            xs[center] += ex
            ys[center] += ey
            guard w > 0 else { continue }
            var k = center - 1
            while k >= 0, click.time - times[k] < w {
                let weight = smoothstep(1 - (click.time - times[k]) / w)
                xs[k] += ex * weight
                ys[k] += ey * weight
                k -= 1
            }
            k = center + 1
            while k < times.count, times[k] - click.time < w {
                let weight = smoothstep(1 - (times[k] - click.time) / w)
                xs[k] += ex * weight
                ys[k] += ey * weight
                k += 1
            }
        }
    }

    private static func smoothstep(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Index of the value closest to `t` in sorted `times`.
    private static func nearestIndex(_ times: [Double], _ t: Double) -> Int? {
        guard !times.isEmpty else { return nil }
        let i = lastIndex(atOrBefore: t, in: times) ?? 0
        if i + 1 < times.count, abs(times[i + 1] - t) < abs(times[i] - t) { return i + 1 }
        return i
    }

    /// Last index with `times[i] <= t` (binary search), `nil` if `t` precedes all.
    static func lastIndex(atOrBefore t: Double, in times: [Double]) -> Int? {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo == 0 ? nil : lo - 1
    }
}

/// A cursor track ready for per-frame sampling: raw samples plus their
/// smoothed path, with idle detection for "hide when idle".
public struct CursorPath: Sendable {
    /// Raw samples, time-sorted.
    public let raw: [CursorSample]
    /// Smoothed path (`raw` when smoothing is 0).
    public let smoothed: [CursorSample]
    public let smoothing: Double
    public let parameters: CursorSmoothing.Parameters
    /// Mouse-down times, sorted.
    public let clickTimes: [Double]

    private let rawTimes: [Double]
    private let smoothTimes: [Double]
    /// Per raw sample: time of the last movement beyond the dead zone.
    private let lastMoveTimes: [Double]

    public init(
        samples: [CursorSample],
        clicks: [RecordingClickEvent] = [],
        smoothing: Double,
        parameters: CursorSmoothing.Parameters = .standard
    ) {
        let raw = CursorSmoothing.sortedSamples(samples)
        self.raw = raw
        self.smoothing = smoothing
        self.parameters = parameters
        self.smoothed = CursorSmoothing.smooth(raw, clicks: clicks, smoothing: smoothing, parameters: parameters)
        self.clickTimes = clicks.filter(\.isDown).map(\.time).sorted()
        self.rawTimes = raw.map(\.time)
        self.smoothTimes = smoothed.map(\.time)

        var moves: [Double] = []
        moves.reserveCapacity(raw.count)
        if let first = raw.first {
            var ax = first.x, ay = first.y
            var last = first.time
            let threshold = Float(max(parameters.deadZone, 0))
            for s in raw {
                if hypotf(s.x - ax, s.y - ay) > threshold {
                    ax = s.x
                    ay = s.y
                    last = s.time
                }
                moves.append(last)
            }
        }
        self.lastMoveTimes = moves
    }

    public var isEmpty: Bool { raw.isEmpty }
    public var startTime: Double? { raw.first?.time }
    public var endTime: Double? { raw.last?.time }

    /// Smoothed position at source time `t` (linear between samples, clamped
    /// to the ends), in recording points.
    public func position(at t: Double) -> CGPoint? {
        guard let first = smoothed.first else { return nil }
        guard let i = CursorSmoothing.lastIndex(atOrBefore: t, in: smoothTimes) else {
            return CGPoint(x: Double(first.x), y: Double(first.y))
        }
        let a = smoothed[i]
        guard i + 1 < smoothed.count else { return CGPoint(x: Double(a.x), y: Double(a.y)) }
        let b = smoothed[i + 1]
        let span = b.time - a.time
        let f = span > 0 ? min(max((t - a.time) / span, 0), 1) : 0
        return CGPoint(x: Double(a.x) + (Double(b.x) - Double(a.x)) * f,
                       y: Double(a.y) + (Double(b.y) - Double(a.y)) * f)
    }

    /// Smoothed sample at `t`: interpolated position, raw shape / flags in
    /// effect at `t` (the first sample's before the track starts).
    public func sample(at t: Double) -> CursorSample? {
        guard let point = position(at: t), let first = raw.first else { return nil }
        let step = CursorSmoothing.lastIndex(atOrBefore: t, in: rawTimes).map { raw[$0] } ?? first
        return CursorSample(time: t, x: Float(point.x), y: Float(point.y), shapeIndex: step.shapeIndex, flags: step.flags)
    }

    /// Seconds since the cursor last moved (beyond the dead zone) or clicked;
    /// 0 before the track starts.
    public func idleDuration(at t: Double) -> Double {
        guard let i = CursorSmoothing.lastIndex(atOrBefore: t, in: rawTimes) else { return 0 }
        var last = lastMoveTimes[i]
        if raw[i].flags.contains(.leftDown) || raw[i].flags.contains(.rightDown) || raw[i].flags.contains(.otherDown) {
            last = max(last, raw[i].time)
        }
        if let c = CursorSmoothing.lastIndex(atOrBefore: t, in: clickTimes) {
            last = max(last, clickTimes[c])
        }
        return max(0, t - last)
    }

    /// `true` once the cursor has been still for `delay` seconds.
    public func isIdle(at t: Double, delay: Double) -> Bool {
        idleDuration(at: t) >= delay
    }
}
