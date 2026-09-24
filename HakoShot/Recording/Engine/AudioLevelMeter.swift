import Accelerate
import CoreMedia
import Foundation

/// One audio buffer's level (plan §1.4). Linear values are 0…1 full scale.
nonisolated struct AudioLevelReading: Sendable, Equatable {
    var rms: Float
    var peak: Float
    /// Frames in the buffer and their sample rate (the buffer's duration).
    var frameCount: Int
    var sampleRate: Double

    var rmsDBFS: Float { AudioLevelMath.dBFS(rms) }
    var peakDBFS: Float { AudioLevelMath.dBFS(peak) }
    var duration: Double { sampleRate > 0 ? Double(frameCount) / sampleRate : 0 }
}

/// Pure level math (vDSP): RMS / peak of PCM samples and sample buffers.
nonisolated enum AudioLevelMath {
    /// dBFS of digital silence.
    static let floorDBFS: Float = -120

    /// 20·log10, clamped at `floorDBFS`.
    static func dBFS(_ linear: Float) -> Float {
        guard linear > 0 else { return floorDBFS }
        return max(floorDBFS, 20 * log10(linear))
    }

    static func linear(dBFS: Float) -> Float {
        powf(10, dBFS / 20)
    }

    /// Sum of squares and absolute peak of `samples`.
    static func accumulate(_ samples: UnsafeBufferPointer<Float>) -> (sumOfSquares: Float, peak: Float) {
        guard !samples.isEmpty else { return (0, 0) }
        let squares = vDSP.sumOfSquares(samples)
        let peak = vDSP.maximumMagnitude(samples)
        return (squares, peak)
    }

    /// RMS and peak over all channels of `samples`.
    static func reading(of samples: [Float], sampleRate: Double = 48_000, channels: Int = 1) -> AudioLevelReading {
        samples.withUnsafeBufferPointer { buffer in
            let (squares, peak) = accumulate(buffer)
            let rms = buffer.isEmpty ? 0 : sqrt(squares / Float(buffer.count))
            return AudioLevelReading(rms: rms, peak: peak, frameCount: buffer.count / max(1, channels), sampleRate: sampleRate)
        }
    }

    /// Meter position 0…1 for a level: −60 dBFS (and below) → 0, 0 dBFS → 1,
    /// linear in dB between (for the HUD / control bar bars).
    static func meterPosition(dBFS: Float, floor: Float = -60) -> Float {
        guard dBFS > floor else { return 0 }
        return min(1, (dBFS - floor) / -floor)
    }

    /// Peak hold with a release of `releaseDBPerSecond` over `elapsed`
    /// seconds: the shown peak never drops faster than that.
    static func heldPeak(previous: Float, current: Float, elapsed: Double, releaseDBPerSecond: Float = 24) -> Float {
        let decayed = previous * powf(10, -releaseDBPerSecond * Float(max(0, elapsed)) / 20)
        return max(current, decayed)
    }

    /// Level of a PCM sample buffer (float32 or signed 16/32-bit integer,
    /// interleaved or not). `nil` for compressed or unreadable buffers.
    static func reading(of sampleBuffer: CMSampleBuffer) -> AudioLevelReading? {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM
        else { return nil }
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let bits = Int(asbd.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && (bits == 16 || bits == 32)) else { return nil }
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr, sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPointer = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: listPointer, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer
        ) == noErr else { return nil }

        var squares: Float = 0
        var peak: Float = 0
        var count = 0
        var scratch: [Float] = []
        for buffer in UnsafeMutableAudioBufferListPointer(listPointer) {
            guard let data = buffer.mData else { continue }
            let bytes = Int(buffer.mDataByteSize)
            if isFloat {
                let n = bytes / 4
                let (s, p) = accumulate(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: n))
                squares += s
                peak = max(peak, p)
                count += n
            } else if bits == 16 {
                let n = bytes / 2
                scratch = [Float](repeating: 0, count: n)
                vDSP.convertElements(of: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: n), to: &scratch)
                vDSP.multiply(1 / 32_768, scratch, result: &scratch)
                scratch.withUnsafeBufferPointer { let (s, p) = accumulate($0); squares += s; peak = max(peak, p) }
                count += n
            } else {
                let n = bytes / 4
                scratch = [Float](repeating: 0, count: n)
                vDSP.convertElements(of: UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: n), to: &scratch)
                vDSP.multiply(1 / 2_147_483_648, scratch, result: &scratch)
                scratch.withUnsafeBufferPointer { let (s, p) = accumulate($0); squares += s; peak = max(peak, p) }
                count += n
            }
        }
        guard count > 0 else { return nil }
        return AudioLevelReading(
            rms: sqrt(squares / Float(count)), peak: min(1, peak),
            frameCount: frameCount, sampleRate: asbd.mSampleRate
        )
    }
}

/// "The mic is on but nothing comes in" (plan §1.4): the flag goes up once
/// the level has stayed at or below `thresholdDBFS` for `minimumDuration`
/// seconds of audio, and drops on the first louder buffer. Time is counted
/// in buffer durations, so it is exact for tests and independent of delivery
/// jitter.
nonisolated struct SilenceDetector: Sendable, Equatable {
    var thresholdDBFS: Float = -60
    var minimumDuration: Double = 3
    private(set) var silentDuration: Double = 0

    init(thresholdDBFS: Float = -60, minimumDuration: Double = 3) {
        self.thresholdDBFS = thresholdDBFS
        self.minimumDuration = minimumDuration
    }

    var isSilent: Bool { silentDuration >= minimumDuration }

    /// Feeds one buffer (its peak level and duration); returns `isSilent`.
    @discardableResult
    mutating func add(peakDBFS: Float, duration: Double) -> Bool {
        if peakDBFS <= thresholdDBFS {
            silentDuration += max(0, duration)
        } else {
            silentDuration = 0
        }
        return isSilent
    }

    mutating func reset() {
        silentDuration = 0
    }
}

/// Live per-track levels for `RecordingStats.microphoneLevel` /
/// `systemAudioLevel` and the silent-mic flag (plan §1.4, §4.7).
///
/// `process` runs on the source's audio queue for every buffer (before the
/// writer, so levels also move while paused); readers poll from any thread.
nonisolated final class AudioLevelMeter: @unchecked Sendable {
    // @unchecked: all state guarded by `lock`.
    private struct TrackState {
        var heldPeak: Float = 0
        var lastReading: AudioLevelReading?
        var silence = SilenceDetector()
    }

    private let lock = NSLock()
    private var tracks: [AudioTrackKind: TrackState] = [:]

    init() {}

    /// Measures one buffer of `kind`.
    func process(_ sampleBuffer: CMSampleBuffer, kind: AudioTrackKind) {
        guard let reading = AudioLevelMath.reading(of: sampleBuffer) else { return }
        record(reading, kind: kind)
    }

    /// Feeds an already measured buffer (tests, other sources).
    func record(_ reading: AudioLevelReading, kind: AudioTrackKind) {
        lock.withLock {
            var state = tracks[kind] ?? TrackState()
            state.heldPeak = AudioLevelMath.heldPeak(previous: state.heldPeak, current: reading.peak, elapsed: reading.duration)
            state.lastReading = reading
            state.silence.add(peakDBFS: reading.peakDBFS, duration: reading.duration)
            tracks[kind] = state
        }
    }

    /// Held peak level, 0…1 linear (contract of `RecordingStats`); 0 before
    /// the first buffer.
    func level(_ kind: AudioTrackKind) -> Float {
        lock.withLock { tracks[kind]?.heldPeak ?? 0 }
    }

    /// The newest buffer's reading.
    func lastReading(_ kind: AudioTrackKind) -> AudioLevelReading? {
        lock.withLock { tracks[kind]?.lastReading }
    }

    /// At least 3 s at or below −60 dBFS on `kind`.
    func isSilent(_ kind: AudioTrackKind) -> Bool {
        lock.withLock { tracks[kind]?.silence.isSilent ?? false }
    }

    /// Seconds of silence so far on `kind`.
    func silentDuration(_ kind: AudioTrackKind) -> Double {
        lock.withLock { tracks[kind]?.silence.silentDuration ?? 0 }
    }

    func reset() {
        lock.withLock { tracks.removeAll() }
    }
}
