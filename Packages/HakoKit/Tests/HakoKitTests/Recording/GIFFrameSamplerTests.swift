import Testing
@testable import HakoKit

@Suite("GIFFrameSampler")
struct GIFFrameSamplerTests {
    @Test func fifteenFPSDelays() {
        let s = GIFFrameSampler(fps: 15, duration: 2)
        #expect(s.frameCount == 30)
        #expect(Array(s.delays.prefix(6)) == [7, 7, 6, 7, 7, 6])
        #expect(s.delays.reduce(0, +) == 200)
        #expect(s.totalCentiseconds == 200)
        #expect(Set(s.delays) == [6, 7])
        #expect(Array(s.startCentiseconds.prefix(4)) == [0, 7, 14, 20])
    }

    @Test(arguments: [
        (15, 3.37), (10, 1.0), (24, 5.55), (30, 0.99), (20, 12.345), (5, 0.3), (50, 1.01), (7, 2.5),
    ])
    func delaysSumToDuration(fps: Int, duration: Double) {
        let s = GIFFrameSampler(fps: fps, duration: duration)
        #expect(s.delays.reduce(0, +) == Int((duration * 100).rounded()))
        #expect(s.delays.allSatisfy { $0 >= GIFFrameSampler.minimumDelay })
        #expect(s.delays.count == s.startCentiseconds.count)
        // Frame count ≈ fps × duration.
        #expect(abs(Double(s.frameCount) - Double(fps) * duration) <= 1)
    }

    @Test func tinyTailFoldsIntoPreviousFrame() {
        // 1.01 s at 10 fps: grid ends at 100 cs, 1 cs left → merged.
        let s = GIFFrameSampler(fps: 10, duration: 1.01)
        #expect(s.frameCount == 10)
        #expect(s.delays.last == 11)
        #expect(s.delays.reduce(0, +) == 101)
    }

    @Test func edgeCases() {
        #expect(GIFFrameSampler(fps: 15, duration: 0).frameCount == 0)
        #expect(GIFFrameSampler(fps: 15, duration: -3).frameCount == 0)
        #expect(GIFFrameSampler(fps: 15, duration: 0.01).delays == [1]) // single frame kept
        #expect(GIFFrameSampler(fps: 500, duration: 1).fps == 50)
        #expect(GIFFrameSampler(fps: 0, duration: 1).fps == 1)
        #expect(GIFFrameSampler.estimatedFrameCount(duration: 4, fps: 15) == 60)
        #expect(GIFFrameSampler.estimatedFrameCount(duration: 10, fps: 24) == 240)
    }

    @Test func sampleVFRSource() {
        // Source: frames at 0, 0.05, 0.3, 0.31, 0.9 (irregular).
        let times = [0.0, 0.05, 0.3, 0.31, 0.9]
        let s = GIFFrameSampler(fps: 10, duration: 1)
        let slots = s.sample(sourceFrameTimes: times)
        #expect(slots.count == 10)
        #expect(slots.map(\.sourceIndex) == [0, 1, 1, 2, 3, 3, 3, 3, 3, 4])
        #expect(slots.allSatisfy { $0.delayCentiseconds == 10 })
        // First source frame starts late → still shown at t = 0.
        #expect(s.sample(sourceFrameTimes: [0.25, 0.5]).map(\.sourceIndex) == [0, 0, 0, 0, 0, 1, 1, 1, 1, 1])
        #expect(s.sample(sourceFrameTimes: []).isEmpty)
    }

    @Test func mergeRepeatedFrames() {
        let s = GIFFrameSampler(fps: 10, duration: 1)
        let slots = s.sample(sourceFrameTimes: [0.0, 0.05, 0.3, 0.31, 0.9])
        let merged = GIFFrameSampler.mergeRepeats(slots)
        #expect(merged == [
            GIFFrameSlot(sourceIndex: 0, delayCentiseconds: 10),
            GIFFrameSlot(sourceIndex: 1, delayCentiseconds: 20),
            GIFFrameSlot(sourceIndex: 2, delayCentiseconds: 10),
            GIFFrameSlot(sourceIndex: 3, delayCentiseconds: 50),
            GIFFrameSlot(sourceIndex: 4, delayCentiseconds: 10),
        ])
        #expect(merged.map(\.delayCentiseconds).reduce(0, +) == 100)

        // Content-key merge: frames 1 and 2 are distinct sources with equal content.
        let contentOf = [0: "a", 1: "b", 2: "b", 3: "a"]
        let byContent = GIFFrameSampler.mergeRepeats([
            GIFFrameSlot(sourceIndex: 0, delayCentiseconds: 7),
            GIFFrameSlot(sourceIndex: 1, delayCentiseconds: 7),
            GIFFrameSlot(sourceIndex: 2, delayCentiseconds: 6),
            GIFFrameSlot(sourceIndex: 3, delayCentiseconds: 7),
        ]) { contentOf[$0.sourceIndex]! }
        #expect(byContent.map(\.sourceIndex) == [0, 1, 3])
        #expect(byContent.map(\.delayCentiseconds) == [7, 13, 7])
    }

    @Test func streamingMerger() {
        var merger = GIFRepeatMerger<String, Int>()
        var out: [(String, Int)] = []
        for (frame, key) in [("a", 1), ("b", 1), ("c", 2), ("d", 3), ("e", 3), ("f", 3)] {
            if let emitted = merger.add(frame, key: key, delayCentiseconds: 7) {
                out.append((emitted.frame, emitted.delayCentiseconds))
            }
        }
        if let last = merger.finish() { out.append((last.frame, last.delayCentiseconds)) }
        #expect(out.map(\.0) == ["a", "c", "d"])
        #expect(out.map(\.1) == [14, 7, 21])
        #expect(merger.finish()?.frame == nil)
    }

    @Test func contentHash() {
        let a: [UInt8] = Array(0..<64)
        var b = a
        b[37] = 0
        func hash(_ bytes: [UInt8], rowBytes: Int = 16, bytesPerRow: Int = 16, height: Int = 4) -> UInt64 {
            bytes.withUnsafeBytes {
                GIFFrameSampler.contentHash(bytes: $0, rowBytes: rowBytes, bytesPerRow: bytesPerRow, height: height)
            }
        }
        #expect(hash(a) == hash(a))
        #expect(hash(a) != hash(b))
        // Row padding is ignored: rows of 12 bytes with a 16-byte stride.
        var padded = a
        padded[13] = 99
        #expect(hash(a, rowBytes: 12) == hash(padded, rowBytes: 12))
        // Odd tails are hashed byte by byte.
        var tail = a
        tail[10] = 200
        #expect(hash(a, rowBytes: 11) != hash(tail, rowBytes: 11))
    }

    @Test func sizeEstimate() {
        let big = GIFFrameSampler.estimatedByteCount(width: 1200, height: 800, duration: 60, fps: 30, optimize: false)
        #expect(big > GIFFrameSampler.largeGIFWarningBytes)
        let small = GIFFrameSampler.estimatedByteCount(width: 800, height: 450, duration: 5, fps: 15, optimize: true)
        #expect(small < GIFFrameSampler.largeGIFWarningBytes)
    }
}
