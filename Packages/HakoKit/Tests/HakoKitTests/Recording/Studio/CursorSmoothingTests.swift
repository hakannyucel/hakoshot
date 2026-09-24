import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("CursorSmoothing")
struct CursorSmoothingTests {
    /// Deterministic pseudo-noise in `-1…1`.
    static func noise(_ i: Int) -> Double {
        let x = sin(Double(i) * 12.9898) * 43_758.5453
        return (x - x.rounded(.down)) * 2 - 1
    }

    /// 3 s of a fast, jittery loop at 60 Hz (±2 pt noise).
    static func jitteryLoop() -> [CursorSample] {
        (0..<180).map { i in
            let t = Double(i) / 60
            let x = 400 + 250 * cos(t * 2.3) + 2 * noise(i)
            let y = 300 + 180 * sin(t * 3.1) + 2 * noise(i + 1000)
            return CursorSample(time: t, x: Float(x), y: Float(y), shapeIndex: UInt16(i / 60))
        }
    }

    static func rawPoint(_ samples: [CursorSample], at t: Double) -> CGPoint {
        CursorPath(samples: samples, smoothing: 0).position(at: t) ?? .zero
    }

    @Test func timeConstantMapping() {
        #expect(CursorSmoothing.timeConstant(forSmoothing: 0) == 0)
        #expect(abs(CursorSmoothing.timeConstant(forSmoothing: 0.6) - 0.072) < 1e-12)
        #expect(CursorSmoothing.timeConstant(forSmoothing: 5) == 0.12)
    }

    @Test func zeroSmoothingIsIdentity() {
        let samples = Self.jitteryLoop()
        let clicks = [RecordingClickEvent(time: 1.0, x: 10, y: 10)]
        #expect(CursorSmoothing.smooth(samples, clicks: clicks, smoothing: 0) == samples)
        let path = CursorPath(samples: samples, clicks: clicks, smoothing: 0)
        for s in samples {
            let p = path.position(at: s.time)
            #expect(p == CGPoint(x: Double(s.x), y: Double(s.y)))
        }
    }

    @Test(arguments: [0.2, 0.6, 1.0])
    func clicksArePinned(smoothing: Double) throws {
        let samples = Self.jitteryLoop()
        // Off-grid times, click points 3 pt off the raw path, and a double
        // click 90 ms apart.
        var clicks: [RecordingClickEvent] = []
        for t in [0.2071, 0.9, 1.5037, 1.5937, 2.95] {
            let raw = Self.rawPoint(samples, at: t)
            clicks.append(RecordingClickEvent(time: t, x: raw.x + 3, y: raw.y - 3, isDown: true))
            clicks.append(RecordingClickEvent(time: t + 0.03, x: raw.x, y: raw.y, isDown: false)) // ups ignored
        }
        let path = CursorPath(samples: samples, clicks: clicks, smoothing: smoothing)
        for click in clicks where click.isDown {
            let p = try #require(path.position(at: click.time))
            let error = hypot(p.x - click.x, p.y - click.y)
            #expect(error < 0.5, "t=\(click.time) error=\(error)")
        }
    }

    @Test func smoothingReducesJitterWithoutLag() {
        let samples = Self.jitteryLoop()
        let smoothed = CursorSmoothing.smooth(samples, smoothing: 0.6)
        func roughness(_ s: [CursorSample]) -> Double {
            guard s.count > 2 else { return 0 }
            var sum = 0.0
            for i in 1..<(s.count - 1) {
                let ax = Double(s[i - 1].x) - 2 * Double(s[i].x) + Double(s[i + 1].x)
                let ay = Double(s[i - 1].y) - 2 * Double(s[i].y) + Double(s[i + 1].y)
                sum += ax * ax + ay * ay
            }
            return sum / Double(s.count - 2)
        }
        // Compare on the same 60 Hz grid.
        let path = CursorPath(samples: samples, smoothing: 0.6)
        let resampled = samples.map { s -> CursorSample in
            let p = path.position(at: s.time) ?? .zero
            return CursorSample(time: s.time, x: Float(p.x), y: Float(p.y))
        }
        #expect(roughness(resampled) < roughness(samples) * 0.25)
        // Forward-backward: no systematic lag, stays close to the noiseless loop.
        var maxDeviation = 0.0
        for s in resampled where s.time > 0.3 && s.time < 2.6 {
            let x = 400 + 250 * cos(s.time * 2.3), y = 300 + 180 * sin(s.time * 3.1)
            maxDeviation = max(maxDeviation, hypot(Double(s.x) - x, Double(s.y) - y))
        }
        #expect(maxDeviation < 12)
        #expect(smoothed.first?.time == 0)
        #expect(smoothed.last?.time == samples.last?.time)
    }

    @Test func stillCursorHasNoJitter() {
        let samples = (0..<120).map { i in
            CursorSample(time: Double(i) / 60, x: Float(100 + 0.2 * Self.noise(i)), y: Float(50 + 0.2 * Self.noise(i + 7)))
        }
        let smoothed = CursorSmoothing.smooth(samples, smoothing: 0.6)
        let first = smoothed[0]
        #expect(smoothed.allSatisfy { $0.x == first.x && $0.y == first.y })
    }

    @Test func samplingInterpolatesAndClamps() throws {
        let samples = [
            CursorSample(time: 1, x: 0, y: 0, shapeIndex: 0),
            CursorSample(time: 2, x: 10, y: 20, shapeIndex: 3, flags: .leftDown),
            CursorSample(time: 3, x: 10, y: 20, shapeIndex: 4, flags: .hidden),
        ]
        let path = CursorPath(samples: samples.reversed(), smoothing: 0) // unsorted input
        #expect(path.position(at: 1.5) == CGPoint(x: 5, y: 10))
        #expect(path.position(at: 0) == CGPoint(x: 0, y: 0))
        #expect(path.position(at: 9) == CGPoint(x: 10, y: 20))
        let mid = try #require(path.sample(at: 2.5))
        #expect(mid.shapeIndex == 3 && mid.flags == .leftDown)
        #expect(path.sample(at: 3)?.flags == .hidden)
        #expect(path.sample(at: 0.5)?.shapeIndex == 0)
        #expect(CursorPath(samples: [], smoothing: 0.5).position(at: 1) == nil)
        // Smoothed paths still start and end on the raw ends.
        let smooth = CursorPath(samples: samples, smoothing: 0.8)
        #expect(smooth.sample(at: 2.5)?.shapeIndex == 3)
        #expect(smooth.startTime == 1 && smooth.endTime == 3)
    }

    @Test func idleDetection() {
        // Moves for 1 s, then still until 5 s; click at 4 s.
        var samples: [CursorSample] = []
        for i in 0...300 {
            let t = Double(i) / 60
            let x = t < 1 ? t * 100 : 100
            samples.append(CursorSample(time: t, x: Float(x), y: 0))
        }
        let path = CursorPath(samples: samples, clicks: [RecordingClickEvent(time: 4, x: 100, y: 0)], smoothing: 0.6)
        #expect(path.idleDuration(at: 0.5) < 0.02)
        #expect(abs(path.idleDuration(at: 3) - 2) < 0.03)
        #expect(path.isIdle(at: 3.5, delay: 2))
        #expect(!path.isIdle(at: 1.5, delay: 2))
        #expect(abs(path.idleDuration(at: 4.5) - 0.5) < 1e-9)
        #expect(path.idleDuration(at: -1) == 0)
    }
}
