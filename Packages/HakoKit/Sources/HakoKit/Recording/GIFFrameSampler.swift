import Foundation

/// One output GIF frame: which source frame to show and for how long.
public struct GIFFrameSlot: Sendable, Hashable {
    /// Index into the source frame list.
    public var sourceIndex: Int
    /// Delay in 1/100 s.
    public var delayCentiseconds: Int

    public init(sourceIndex: Int, delayCentiseconds: Int) {
        self.sourceIndex = sourceIndex
        self.delayCentiseconds = delayCentiseconds
    }
}

/// Maps a variable-frame-rate source onto a constant GIF frame grid
/// (plan §1.7, §4.17).
///
/// GIF delays are whole centiseconds. Grid frame `i` starts at
/// `ceil(i × 100 / fps)` cs, so the rounding error is spread out
/// (15 fps → 7, 7, 6, 7, 7, 6 …) and the delays sum exactly to the
/// duration rounded to the nearest centisecond. A final sliver shorter than
/// `minimumDelay` is folded into the previous frame, because browsers
/// stretch delays below 2 cs to 10 cs.
public struct GIFFrameSampler: Sendable, Hashable {
    public static let minimumDelay = 2

    public let fps: Int
    /// Total length in centiseconds (= sum of `delays`).
    public let totalCentiseconds: Int
    /// Start of every output frame, in centiseconds.
    public let startCentiseconds: [Int]
    /// Delay of every output frame, in centiseconds.
    public let delays: [Int]

    /// - Parameters:
    ///   - fps: target rate, clamped to `1…GIFExportOptions.maxFPS`.
    ///   - duration: output length in seconds.
    public init(fps: Int, duration: Double) {
        let rate = min(max(fps, 1), GIFExportOptions.maxFPS)
        self.fps = rate
        let total = duration.isFinite ? max(0, Int((duration * 100).rounded())) : 0
        self.totalCentiseconds = total

        var starts: [Int] = []
        var i = 0
        while true {
            let start = (i * 100 + rate - 1) / rate // ceil(i·100/fps)
            if start >= total { break }
            starts.append(start)
            i += 1
        }
        var delays: [Int] = []
        delays.reserveCapacity(starts.count)
        for (k, start) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1] : total
            delays.append(end - start)
        }
        if delays.count > 1, let last = delays.last, last < Self.minimumDelay {
            delays.removeLast()
            starts.removeLast()
            delays[delays.count - 1] += last
        }
        self.startCentiseconds = starts
        self.delays = delays
    }

    public var frameCount: Int { delays.count }

    /// Sample time (seconds) of every output frame: its grid start.
    public var sampleTimes: [Double] { startCentiseconds.map { Double($0) / 100 } }

    /// Picks, for each output frame, the source frame on screen at the
    /// frame's start: the last source frame whose presentation time is
    /// `≤` the sample time (the first source frame before it starts).
    /// `sourceFrameTimes` must be ascending; times are output-relative
    /// seconds. Returns one slot per output frame (no merging).
    public func sample(sourceFrameTimes: [Double]) -> [GIFFrameSlot] {
        guard !sourceFrameTimes.isEmpty else { return [] }
        var slots: [GIFFrameSlot] = []
        slots.reserveCapacity(frameCount)
        var cursor = 0
        let epsilon = 1e-6
        for (k, start) in startCentiseconds.enumerated() {
            let t = Double(start) / 100
            while cursor + 1 < sourceFrameTimes.count, sourceFrameTimes[cursor + 1] <= t + epsilon {
                cursor += 1
            }
            slots.append(GIFFrameSlot(sourceIndex: cursor, delayCentiseconds: delays[k]))
        }
        return slots
    }

    /// Output frame count for `duration` seconds at `fps` (before merging).
    public static func estimatedFrameCount(duration: Double, fps: Int) -> Int {
        GIFFrameSampler(fps: fps, duration: duration).frameCount
    }

    /// Rough GIF size in bytes, for the "This GIF will be large" warning
    /// (plan §4.17, > 50 MB). Heuristic: ~0.5 byte per pixel per frame
    /// (LZW on screen content), ×0.7 when repeats are merged.
    public static func estimatedByteCount(width: Int, height: Int, duration: Double, fps: Int, optimize: Bool) -> Int {
        let frames = Double(estimatedFrameCount(duration: duration, fps: fps))
        let perFrame = Double(max(0, width) * max(0, height)) * 0.5
        return Int(frames * perFrame * (optimize ? 0.7 : 1))
    }

    public static let largeGIFWarningBytes = 50_000_000

    // MARK: Merging repeats

    /// Merges consecutive slots that show the same source frame, summing
    /// their delays.
    public static func mergeRepeats(_ slots: [GIFFrameSlot]) -> [GIFFrameSlot] {
        mergeRepeats(slots) { $0.sourceIndex }
    }

    /// Merges consecutive slots whose `key` is equal (e.g. a content hash
    /// of the source frame), summing their delays. The first slot of each
    /// run is kept.
    public static func mergeRepeats<Key: Equatable>(
        _ slots: [GIFFrameSlot],
        key: (GIFFrameSlot) -> Key
    ) -> [GIFFrameSlot] {
        var result: [GIFFrameSlot] = []
        result.reserveCapacity(slots.count)
        var lastKey: Key?
        for slot in slots {
            let k = key(slot)
            if let lastKey, lastKey == k, !result.isEmpty {
                result[result.count - 1].delayCentiseconds += slot.delayCentiseconds
            } else {
                result.append(slot)
            }
            lastKey = k
        }
        return result
    }

    // MARK: Frame hashing

    /// 64-bit content hash of a pixel buffer for repeat detection. Reads
    /// 8 bytes at a time (FNV-style mix); rows are hashed up to
    /// `rowBytes` so row padding is ignored.
    public static func contentHash(
        bytes: UnsafeRawBufferPointer,
        rowBytes: Int,
        bytesPerRow: Int,
        height: Int
    ) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        let prime: UInt64 = 0x0000_0100_0000_01b3
        guard let base = bytes.baseAddress, rowBytes > 0, height > 0,
              bytesPerRow >= rowBytes, bytes.count >= bytesPerRow * (height - 1) + rowBytes
        else { return hash }
        let words = rowBytes / 8
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for w in 0..<words {
                let v = row.loadUnaligned(fromByteOffset: w * 8, as: UInt64.self)
                hash = (hash ^ v) &* prime
            }
            for b in (words * 8)..<rowBytes {
                hash = (hash ^ UInt64(row.load(fromByteOffset: b, as: UInt8.self))) &* prime
            }
        }
        return hash
    }
}

/// Streaming repeat merger for the GIF pipeline: frames arrive one at a
/// time, and a frame is released only when the next different frame (or
/// `finish()`) proves its final delay. The encoder can then write each
/// frame once with the right delay.
public struct GIFRepeatMerger<Frame, Key: Equatable> {
    private var pending: (frame: Frame, key: Key, delay: Int)?

    public init() {}

    /// Adds a frame. Returns the previous frame with its final delay when
    /// `key` differs from it; `nil` when merged (or on the first frame).
    public mutating func add(_ frame: Frame, key: Key, delayCentiseconds: Int) -> (frame: Frame, delayCentiseconds: Int)? {
        if let p = pending, p.key == key {
            pending = (p.frame, p.key, p.delay + delayCentiseconds)
            return nil
        }
        let out = pending.map { (frame: $0.frame, delayCentiseconds: $0.delay) }
        pending = (frame, key, delayCentiseconds)
        return out
    }

    /// Releases the last pending frame.
    public mutating func finish() -> (frame: Frame, delayCentiseconds: Int)? {
        defer { pending = nil }
        return pending.map { (frame: $0.frame, delayCentiseconds: $0.delay) }
    }
}

extension GIFRepeatMerger: Sendable where Frame: Sendable, Key: Sendable {}
