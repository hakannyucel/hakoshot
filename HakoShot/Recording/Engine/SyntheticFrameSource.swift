#if DEBUG
import AVFAudio
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import os

/// DEBUG frame source: a moving test pattern at the requested fps and size
/// (plan §4.5). Runs the same writer / finalize path as the screen stream,
/// with the screen locked and without Screen Recording permission.
///
/// Pattern (420v, BT.709 video range, top-left origin):
/// - dark gray background (Y 60);
/// - a red square (¼ of the short side) moving right 8 px per frame and
///   bouncing vertically;
/// - a 32-cell strip across the top encoding the frame number in binary
///   (cell = white for 1, black for 0, most significant bit first), so a
///   frame extracted from the file tells which frame it was.
///
/// Every frame is `.complete`, stamped with the host clock at generation.
///
/// Audio (R2.1): with system audio on, a 440 Hz sine goes out as `.system`;
/// with a microphone, an 880 Hz sine as `.microphone`. Float32 48 kHz stereo
/// (like SCStream), 1024-frame buffers, amplitude 0.25 (−12 dBFS peak).
/// Buffer PTS = host time at `start` + frames emitted / 48 kHz (continuous,
/// sample-exact); a buffer goes out once its last frame is in the past.
nonisolated final class SyntheticFrameSource: RecordingFrameSource, @unchecked Sendable {
    // @unchecked: all mutable state is only touched on `queue`.

    /// BT.709 video-range colors (Y, Cb, Cr).
    enum Color {
        static let background: (UInt8, UInt8, UInt8) = (60, 128, 128)
        static let square: (UInt8, UInt8, UInt8) = (63, 102, 240)
        static let bitOn: (UInt8, UInt8, UInt8) = (235, 128, 128)
        static let bitOff: (UInt8, UInt8, UInt8) = (16, 128, 128)
    }

    static let counterBits = 32

    private let queue = DispatchQueue(label: "com.hakanyucel.HakoShot.recording.synthetic", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var formatDescription: CMVideoFormatDescription?
    private var handlers: RecordingFrameSourceHandlers?
    private var width = 0
    private var height = 0
    private var fps = 60
    private var frameIndex = 0

    // Audio (on `queue`).
    static let audioSampleRate = 48_000
    static let audioChannelCount = 2
    static let audioFramesPerBuffer = 1024
    static let toneAmplitude: Float = 0.25
    /// Tone per track kind.
    static func toneFrequency(_ kind: AudioTrackKind) -> Double {
        switch kind {
        case .system: 440
        case .microphone: 880
        }
    }

    private var audioTimer: DispatchSourceTimer?
    private var audioKinds: [AudioTrackKind] = []
    private var audioStart: CMTime = .zero
    private var audioFramesEmitted: Int64 = 0
    private var audioFormat: AVAudioFormat?

    init() {}

    /// Strip height in pixels for a frame height.
    static func counterStripHeight(forHeight height: Int) -> Int { max(8, height / 24) & ~1 }

    func start(_ configuration: RecordingSourceConfiguration, handlers: RecordingFrameSourceHandlers) async throws {
        let width = max(2, Int(configuration.pixelSize.width)) & ~1
        let height = max(2, Int(configuration.pixelSize.height)) & ~1
        let fps = max(1, configuration.fps)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess, let pool else {
            throw RecordingError.sourceFailed("synthetic: pixel buffer pool \(width)x\(height)")
        }
        let box = PoolBox(pool: pool)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.pool = box.pool
                self.formatDescription = nil
                self.handlers = handlers
                self.width = width
                self.height = height
                self.fps = fps
                self.frameIndex = 0
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(500))
                timer.setEventHandler { [weak self] in self?.emitFrame() }
                self.timer = timer
                timer.resume()

                var kinds: [AudioTrackKind] = []
                if configuration.microphone != nil { kinds.append(.microphone) }
                if configuration.capturesSystemAudio { kinds.append(.system) }
                self.audioKinds = kinds
                self.audioTimer = nil
                if !kinds.isEmpty {
                    self.audioFormat = AVAudioFormat(
                        commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.audioSampleRate),
                        channels: AVAudioChannelCount(Self.audioChannelCount), interleaved: false
                    )
                    self.audioStart = CMClockGetTime(CMClockGetHostTimeClock())
                    self.audioFramesEmitted = 0
                    let audioTimer = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
                    audioTimer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5), leeway: .milliseconds(1))
                    audioTimer.setEventHandler { [weak self] in self?.emitDueAudio() }
                    self.audioTimer = audioTimer
                    audioTimer.resume()
                }
                continuation.resume()
            }
        }
        Log.recording.notice("synthetic source started: \(width)x\(height) px @\(fps) fps, tones: system \(configuration.capturesSystemAudio), mic \(configuration.microphone != nil)")
    }

    func stop() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.timer?.cancel()
                self.timer = nil
                // Flush complete tone buffers up to now (the writer refuses
                // anything after the stop instant).
                self.emitDueAudio()
                self.audioTimer?.cancel()
                self.audioTimer = nil
                self.handlers = nil
                self.pool = nil
                continuation.resume()
            }
        }
    }

    // MARK: Frames (on `queue`)

    private func emitFrame() {
        guard let pool, let handlers else { return }
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess, let pixelBuffer else {
            Log.recording.error("synthetic: no pixel buffer")
            return
        }
        Self.tagBT709(pixelBuffer)
        Self.draw(frame: frameIndex, into: pixelBuffer)
        if formatDescription == nil {
            var description: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &description)
            formatDescription = description
        }
        guard let formatDescription else { return }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(fps)),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            Log.recording.error("synthetic: sample buffer error \(status)")
            return
        }
        frameIndex += 1
        handlers.onVideo(sampleBuffer)
    }

    // MARK: Audio (on `queue`)

    /// Emits every buffer whose last frame is at or before now.
    private func emitDueAudio() {
        guard let handlers, let audioFormat, !audioKinds.isEmpty else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let rate = Int64(Self.audioSampleRate)
        let frames = Int64(Self.audioFramesPerBuffer)
        while audioStart + CMTime(value: audioFramesEmitted + frames, timescale: CMTimeScale(rate)) <= now {
            let pts = audioStart + CMTime(value: audioFramesEmitted, timescale: CMTimeScale(rate))
            for kind in audioKinds {
                guard let buffer = Self.makeToneBuffer(
                    format: audioFormat, frequency: Self.toneFrequency(kind), startFrame: audioFramesEmitted,
                    frameCount: Int(frames), pts: pts
                ) else {
                    Log.recording.error("synthetic: audio buffer error")
                    continue
                }
                handlers.onAudio(buffer, kind)
            }
            audioFramesEmitted += frames
        }
    }

    /// A sine buffer (same signal on every channel) at host `pts`.
    static func makeToneBuffer(
        format: AVAudioFormat, frequency: Double, startFrame: Int64, frameCount: Int, pts: CMTime,
        amplitude: Float = toneAmplitude
    ) -> CMSampleBuffer? {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channels = pcm.floatChannelData
        else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)
        let step = 2 * Double.pi * frequency / format.sampleRate
        for i in 0..<frameCount {
            // Phase from the absolute frame number: continuous across buffers.
            let phase = (Double(startFrame + Int64(i)) * step).truncatingRemainder(dividingBy: 2 * Double.pi)
            let value = amplitude * Float(sin(phase))
            for channel in 0..<Int(format.channelCount) { channels[channel][i] = value }
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format.formatDescription, sampleCount: frameCount,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: pcm.audioBufferList
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private static func tagBT709(_ buffer: CVPixelBuffer) {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }

    /// Square rect (pixels, top-left origin) for a frame number.
    static func squareRect(frame: Int, width: Int, height: Int) -> CGRect {
        let side = max(2, (min(width, height) / 4) & ~1)
        let strip = counterStripHeight(forHeight: height)
        let travelX = max(1, width - side)
        let travelY = max(1, height - strip - side)
        let x = (frame * 8) % travelX
        let phase = (frame * 4) % (2 * travelY)
        let y = strip + (phase < travelY ? phase : 2 * travelY - phase)
        return CGRect(x: x & ~1, y: y & ~1, width: side, height: side)
    }

    /// Draws the test pattern for `frame` into a 420v buffer.
    static func draw(frame: Int, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { return }
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let luma = lumaBase.assumingMemoryBound(to: UInt8.self)
        let chroma = chromaBase.assumingMemoryBound(to: UInt8.self)

        // Background.
        memset(luma, Int32(Color.background.0), lumaStride * height)
        fillChroma(chroma, stride: chromaStride, x: 0, y: 0, width: width / 2, height: chromaHeight, color: Color.background)

        // Frame counter strip.
        let strip = counterStripHeight(forHeight: height)
        let cellWidth = max(1, width / counterBits)
        for bit in 0..<counterBits {
            let on = (UInt32(truncatingIfNeeded: frame) >> UInt32(counterBits - 1 - bit)) & 1 == 1
            let color = on ? Color.bitOn : Color.bitOff
            let x = (bit * cellWidth) & ~1
            let w = min(cellWidth, width - x) & ~1
            guard w > 0 else { continue }
            fillLuma(luma, stride: lumaStride, x: x, y: 0, width: w, height: strip, value: color.0)
            fillChroma(chroma, stride: chromaStride, x: x / 2, y: 0, width: w / 2, height: strip / 2, color: color)
        }

        // Moving square.
        let square = squareRect(frame: frame, width: width, height: height)
        let sx = Int(square.minX), sy = Int(square.minY), side = Int(square.width)
        let sw = min(side, width - sx), sh = min(side, height - sy)
        guard sw > 0, sh > 0 else { return }
        fillLuma(luma, stride: lumaStride, x: sx, y: sy, width: sw, height: sh, value: Color.square.0)
        fillChroma(chroma, stride: chromaStride, x: sx / 2, y: sy / 2, width: sw / 2, height: sh / 2, color: Color.square)
    }

    private static func fillLuma(_ plane: UnsafeMutablePointer<UInt8>, stride: Int, x: Int, y: Int, width: Int, height: Int, value: UInt8) {
        for row in y..<(y + height) {
            memset(plane + row * stride + x, Int32(value), width)
        }
    }

    /// `x`, `y`, `width`, `height` in chroma samples (CbCr pairs).
    private static func fillChroma(
        _ plane: UnsafeMutablePointer<UInt8>, stride: Int, x: Int, y: Int, width: Int, height: Int,
        color: (UInt8, UInt8, UInt8)
    ) {
        guard width > 0, height > 0 else { return }
        let first = plane + y * stride + x * 2
        for i in 0..<width {
            first[i * 2] = color.1
            first[i * 2 + 1] = color.2
        }
        for row in (y + 1)..<(y + height) {
            memcpy(plane + row * stride + x * 2, first, width * 2)
        }
    }
}

/// `CVPixelBufferPool` is thread-safe; boxed to hand it to the source queue.
private nonisolated struct PoolBox: @unchecked Sendable {
    let pool: CVPixelBufferPool
}
#endif
