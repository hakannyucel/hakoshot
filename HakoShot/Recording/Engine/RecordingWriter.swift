import AVFoundation
import CoreMedia
import Foundation
import HakoKit
import os
import VideoToolbox

/// Encoder settings for one raw recording (plan §1.3, §4.13).
nonisolated struct RecordingWriterConfiguration: Sendable, Equatable {
    var outputURL: URL
    /// Even pixel size from `RecordingOutputPlan`.
    var pixelWidth: Int
    var pixelHeight: Int
    /// Codec actually used (`RecordingOutputPlan.codec`, after the automatic
    /// H.264 → HEVC switch).
    var codec: VideoCodec
    /// Average bitrate in bits/s (`VideoQuality.bitrate`).
    var bitrate: Int
    var fps: Int
    /// Crash safety: parts written so far stay readable (plan §1.3).
    var movieFragmentInterval: Double = 2
    var initialMovieFragmentInterval: Double = 2
    var keyFrameIntervalSeconds: Double = 2
    /// One AAC track per entry, always in `AudioTrackKind` order (microphone,
    /// then system; plan §4.7). Empty = silent recording.
    var audioTracks: [AudioTrackKind] {
        didSet { audioTracks = Self.ordered(audioTracks) }
    }
    /// Raw-file AAC settings: 48 kHz stereo, 192 kbps (the finalizer mixes /
    /// re-encodes to the delivery bitrate, plan §4.14).
    var audioSampleRate = 48_000
    var audioChannelCount = 2
    var audioBitrate = 192_000

    init(
        outputURL: URL,
        pixelWidth: Int,
        pixelHeight: Int,
        codec: VideoCodec,
        bitrate: Int,
        fps: Int,
        audioTracks: [AudioTrackKind] = []
    ) {
        self.outputURL = outputURL
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.codec = codec
        self.bitrate = bitrate
        self.fps = fps
        self.audioTracks = Self.ordered(audioTracks)
    }

    /// Size and codec from the output plan, bitrate from the quality preset.
    init(outputURL: URL, plan: RecordingOutputPlan, quality: VideoQuality, fps: Int, audioTracks: [AudioTrackKind] = []) {
        self.init(
            outputURL: outputURL,
            pixelWidth: plan.pixelWidth,
            pixelHeight: plan.pixelHeight,
            codec: plan.codec,
            bitrate: quality.bitrate(width: plan.pixelWidth, height: plan.pixelHeight, fps: fps, codec: plan.codec),
            fps: fps,
            audioTracks: audioTracks
        )
    }

    /// Unique kinds in track order (microphone, system).
    static func ordered(_ kinds: [AudioTrackKind]) -> [AudioTrackKind] {
        AudioTrackKind.allCases.filter(kinds.contains)
    }

    /// `AVAssetWriterInput` audio output settings: AAC-LC.
    var audioOutputSettings: [String: any Sendable] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = audioChannelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = withUnsafeBytes(of: &layout) { Data($0) }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: audioSampleRate,
            AVNumberOfChannelsKey: audioChannelCount,
            AVEncoderBitRateKey: audioBitrate,
            AVChannelLayoutKey: layoutData,
        ]
    }

    /// `AVAssetWriterInput` video output settings: H.264 High / HEVC Main,
    /// no frame reordering (real time), key frame every 2 s, BT.709 tags.
    var videoOutputSettings: [String: any Sendable] {
        let profile: String = switch codec {
        case .h264: AVVideoProfileLevelH264HighAutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        let compression: [String: any Sendable] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: max(1, Int((Double(fps) * keyFrameIntervalSeconds).rounded())),
            AVVideoMaxKeyFrameIntervalDurationKey: keyFrameIntervalSeconds,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: profile,
        ]
        return [
            AVVideoCodecKey: codec == .hevc ? AVVideoCodecType.hevc.rawValue : AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] as [String: any Sendable],
        ]
    }
}

/// Live counters of a writer (`RecordingEngine.stats`).
nonisolated struct RecordingWriterStats: Sendable, Equatable {
    var framesWritten = 0
    /// Frames refused because the encoder was busy (`isReadyForMoreMediaData == false`).
    var droppedFrames = 0
    /// Session start (first frame PTS, host clock); `nil` before the first frame.
    var sessionStart: CMTime?
    var lastVideoTime: CMTime?
    /// Total paused time after T0 so far (`SampleRetimer.pauseOffset`).
    var pauseOffset: CMTime = .zero
    var isPaused = false
    /// Audio buffers written per track.
    var audioBuffersWritten: [AudioTrackKind: Int] = [:]
    /// Audio buffers refused (encoder busy / overlapping timestamps).
    var audioBuffersDropped = 0
}

/// What `RecordingWriter.finish(at:)` produced.
nonisolated struct RecordingWriterSummary: Sendable, Equatable {
    /// First frame PTS on the host clock (media time 0).
    var sessionStart: CMTime
    /// `endSession(atSourceTime:)` value (retimed, host clock minus pauses).
    var sessionEnd: CMTime
    var framesWritten: Int
    var droppedFrames: Int
    /// Pauses after T0, host seconds (a pause open at stop ends at the stop time).
    var pauses: [ClosedRange<Double>] = []
    /// Audio tracks in the file, in track order (tracks that got no sample
    /// are left out).
    var audioTracks: [AudioTrackKind] = []

    /// Media seconds.
    var duration: Double { (sessionEnd - sessionStart).seconds }
}

/// `AVAssetWriter` for the raw `screen.mov` (plan §1.3, §4.5).
///
/// Fragmented QuickTime movie (`movieFragmentInterval` 2 s, first fragment
/// after 2 s) so a crash leaves a readable file. The session starts at the
/// **first video frame's PTS** (host clock, T0); samples keep their host-clock
/// timestamps. On stop, `endSession(atSourceTime: stop − pauseOffset)` keeps
/// the last frame on screen until the stop moment (VFR output: SCK only
/// delivers frames when the screen changes).
///
/// Pause / resume (plan §4.6): the source keeps running; `SampleRetimer`
/// drops samples inside a pause and writes the rest at `PTS − pauseOffset`.
/// The newest frame seen while paused is re-stamped at the resume instant so
/// the video shows the current screen right away (SCK sends nothing while the
/// screen is idle). Restart = `cancel()` + a new writer (engine).
///
/// Threading: samples arrive on the frame source's serial queues and are
/// appended right there (no actor hop per frame). Every mutable field is
/// guarded by `lock`; `AVAssetWriter` / inputs are only touched under it or
/// after `acceptsSamples` was cleared.
nonisolated final class RecordingWriter: @unchecked Sendable {
    let configuration: RecordingWriterConfiguration

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInputs: [AudioTrackKind: AVAssetWriterInput]
    private let lock = NSLock()

    // Guarded by `lock`.
    private var stats = RecordingWriterStats()
    private var acceptsSamples = true
    private var failure: String?
    private var failureReported = false
    private var onFailure: (@Sendable (String) -> Void)?

    private var retimer = SampleRetimer()
    /// Newest screen frame received while paused (re-stamped on resume).
    private var heldFrame: CMSampleBuffer?
    /// Host time from which samples are refused (`stopAccepting(after:)`).
    private var cutoff: CMTime?
    /// Retimed end of the last audio buffer per track (no overlaps).
    private var audioEnd: [AudioTrackKind: CMTime] = [:]
    /// Last frame written (retimed), kept only with audio tracks: see
    /// `extendLastFrame(to:)`.
    private var lastVideoSample: CMSampleBuffer?

    /// Creates the file and starts writing. Throws `RecordingError.writerFailed`
    /// when the settings are rejected or the file can't be created.
    init(configuration: RecordingWriterConfiguration) throws {
        self.configuration = configuration
        try? FileManager.default.removeItem(at: configuration.outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mov)
        } catch {
            throw RecordingError.writerFailed(error.localizedDescription)
        }
        writer.movieFragmentInterval = CMTime(seconds: configuration.movieFragmentInterval, preferredTimescale: 600)
        writer.initialMovieFragmentInterval = CMTime(seconds: configuration.initialMovieFragmentInterval, preferredTimescale: 600)

        let settings = configuration.videoOutputSettings
        // An invalid settings dictionary raises an ObjC exception in
        // `AVAssetWriterInput.init`; check first.
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw RecordingError.writerFailed("encoder rejected \(configuration.codec.rawValue) \(configuration.pixelWidth)x\(configuration.pixelHeight)")
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed("cannot add video input") }
        writer.add(input)

        // Audio: one AAC input per source, microphone first (plan §4.7).
        var audioInputs: [AudioTrackKind: AVAssetWriterInput] = [:]
        if !configuration.audioTracks.isEmpty {
            let audioSettings = configuration.audioOutputSettings
            guard writer.canApply(outputSettings: audioSettings, forMediaType: .audio) else {
                throw RecordingError.writerFailed("encoder rejected AAC \(configuration.audioSampleRate) Hz \(configuration.audioChannelCount) ch")
            }
            for kind in configuration.audioTracks {
                let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioInput.expectsMediaDataInRealTime = true
                guard writer.canAdd(audioInput) else { throw RecordingError.writerFailed("cannot add \(kind.rawValue) audio input") }
                writer.add(audioInput)
                audioInputs[kind] = audioInput
            }
        }

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        self.writer = writer
        self.videoInput = input
        self.audioInputs = audioInputs
    }

    /// Called at most once, on the queue of the append that failed.
    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        lock.withLock { onFailure = handler }
    }

    var currentStats: RecordingWriterStats {
        lock.withLock { stats }
    }

    /// Live media duration at `hostTime` (0 before the first frame; frozen
    /// while paused).
    func mediaDuration(at hostTime: CMTime) -> Double {
        lock.withLock {
            guard let start = stats.sessionStart else { return 0 }
            return max(0, (retimer.outputTime(forStopTime: hostTime) - start).seconds)
        }
    }

    var isPaused: Bool {
        lock.withLock { retimer.isPaused }
    }

    /// Host-time timeline so far (origin T0, closed pauses, the open pause);
    /// `nil` before the first frame.
    var timeline: RecordingTimeline? {
        lock.withLock {
            guard let start = stats.sessionStart else { return nil }
            var timeline = RecordingTimeline(origin: start.seconds, pauses: retimer.pauses)
            if let pauseStart = retimer.pauseStart { timeline.beginPause(at: pauseStart.seconds) }
            return timeline
        }
    }

    // MARK: Pause

    /// Stops writing samples stamped at or after host `time`. No-op when paused.
    func pause(at time: CMTime) {
        lock.withLock {
            guard !retimer.isPaused else { return }
            retimer.pause(at: time)
            stats.isPaused = true
        }
    }

    /// Resumes at host `time`: the pause is added to `pauseOffset` and the
    /// newest frame seen during the pause is written at the resume instant.
    func resume(at time: CMTime) {
        let failureToReport = lock.withLock { () -> (String, @Sendable (String) -> Void)? in
            guard retimer.isPaused else { return nil }
            retimer.resume(at: time, sessionStart: stats.sessionStart)
            stats.pauseOffset = retimer.pauseOffset
            stats.isPaused = false
            guard let held = heldFrame else { return nil }
            heldFrame = nil
            guard acceptsSamples, failure == nil else { return nil }
            let outputTime = time - retimer.pauseOffset
            if let last = stats.lastVideoTime, outputTime <= last { return nil }
            guard videoInput.isReadyForMoreMediaData else {
                stats.droppedFrames += 1
                return nil
            }
            if stats.sessionStart == nil {
                // Paused before the first frame: media time starts here.
                writer.startSession(atSourceTime: outputTime)
                stats.sessionStart = outputTime
            }
            guard let buffer = SampleRetimer.restamped(held, at: outputTime), videoInput.append(buffer) else {
                return recordFailure()
            }
            if !audioInputs.isEmpty { lastVideoSample = buffer }
            stats.framesWritten += 1
            stats.lastVideoTime = outputTime
            return nil
        }
        if let (message, handler) = failureToReport { handler(message) }
    }

    // MARK: Samples

    /// Appends one screen frame (source video queue). Returns `false` when
    /// the frame was not written (dropped, paused, stopping or failed).
    @discardableResult
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let (written, failureToReport) = lock.withLock { () -> (Bool, (String, @Sendable (String) -> Void)?) in
            guard acceptsSamples, failure == nil else { return (false, nil) }
            let pts = sampleBuffer.presentationTimeStamp
            guard pts.isValid else { return (false, nil) }
            if let cutoff, pts >= cutoff { return (false, nil) }
            guard let outputTime = retimer.outputTime(forHostTime: pts) else {
                // Inside a pause: keep the newest frame for the resume.
                if retimer.isPaused { heldFrame = sampleBuffer }
                return (false, nil)
            }
            // Timestamps must increase strictly (compared in retimed time).
            if let last = stats.lastVideoTime, outputTime <= last { return (false, nil) }
            guard videoInput.isReadyForMoreMediaData else {
                stats.droppedFrames += 1
                return (false, nil)
            }
            if stats.sessionStart == nil {
                writer.startSession(atSourceTime: pts)
                stats.sessionStart = pts
            }
            guard let buffer = SampleRetimer.retimed(sampleBuffer, by: retimer.pauseOffset), videoInput.append(buffer) else {
                return (false, recordFailure())
            }
            if !audioInputs.isEmpty { lastVideoSample = buffer }
            stats.framesWritten += 1
            stats.lastVideoTime = outputTime
            return (true, nil)
        }
        if let (message, handler) = failureToReport { handler(message) }
        return written
    }

    /// Appends one PCM audio buffer to the `kind` track (source audio
    /// queue). Buffers keep their host-clock PTS like the video, so the
    /// tracks stay in sync: audio before the first video frame (T0) is dropped
    /// (a buffer straddling T0 is trimmed to start at T0), buffers inside a
    /// pause are dropped whole (`SampleRetimer`), the rest are moved back by
    /// `pauseOffset`. Returns whether the buffer was written.
    @discardableResult
    func appendAudio(_ sampleBuffer: CMSampleBuffer, kind: AudioTrackKind) -> Bool {
        let (written, failureToReport) = lock.withLock { () -> (Bool, (String, @Sendable (String) -> Void)?) in
            guard acceptsSamples, failure == nil, let input = audioInputs[kind] else { return (false, nil) }
            // No session yet = no video frame yet: nothing before T0.
            guard let start = stats.sessionStart else { return (false, nil) }
            var buffer = sampleBuffer
            var pts = buffer.presentationTimeStamp
            guard pts.isValid else { return (false, nil) }
            if let cutoff, pts >= cutoff { return (false, nil) }
            if pts < start {
                guard let trimmed = Self.trimmedAudio(buffer, from: start) else { return (false, nil) }
                buffer = trimmed
                pts = trimmed.presentationTimeStamp
            }
            let duration = buffer.duration
            guard let outputTime = retimer.outputTime(forHostTime: pts, duration: duration) else { return (false, nil) }
            // AAC tracks can't overlap (1 ms slack for rounding).
            if let end = audioEnd[kind], outputTime < end - CMTime(value: 1, timescale: 1000) {
                stats.audioBuffersDropped += 1
                return (false, nil)
            }
            guard input.isReadyForMoreMediaData else {
                stats.audioBuffersDropped += 1
                return (false, nil)
            }
            guard let retimed = SampleRetimer.retimed(buffer, by: retimer.pauseOffset), input.append(retimed) else {
                return (false, recordFailure())
            }
            stats.audioBuffersWritten[kind, default: 0] += 1
            audioEnd[kind] = outputTime + (duration.isValid ? duration : .zero)
            return (true, nil)
        }
        if let (message, handler) = failureToReport { handler(message) }
        return written
    }

    /// The part of an LPCM buffer from host time `start` on; `nil` when it
    /// ends before `start` or can't be split.
    static func trimmedAudio(_ sampleBuffer: CMSampleBuffer, from start: CMTime) -> CMSampleBuffer? {
        let pts = sampleBuffer.presentationTimeStamp
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0,
              let format = sampleBuffer.formatDescription,
              let sampleRate = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mSampleRate,
              sampleRate > 0
        else { return nil }
        let skip = Int(((start - pts).seconds * sampleRate - 1e-6).rounded(.up))
        guard skip < frames else { return nil }
        guard skip > 0 else { return sampleBuffer }
        let newPTS = pts + CMTime(value: CMTimeValue(skip), timescale: CMTimeScale(sampleRate.rounded()))
        return copyPCM(sampleBuffer, droppingFrames: skip, totalFrames: frames, pts: newPTS)
    }

    /// A new LPCM sample buffer with the first `skip` frames removed, at
    /// `pts`. (`CMSampleBufferCopySampleBufferForRange` refuses buffers built
    /// from an AudioBufferList: "cannot subdivide".)
    private static func copyPCM(_ sampleBuffer: CMSampleBuffer, droppingFrames skip: Int, totalFrames: Int, pts: CMTime) -> CMSampleBuffer? {
        guard let format = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBytesPerFrame > 0
        else { return nil }
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil
        ) == noErr, sizeNeeded > 0 else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block
        ) == noErr else { return nil }
        // Every buffer (one per channel, or one interleaved) holds whole
        // frames of `mBytesPerFrame`; move each start past the skipped frames.
        let offset = skip * Int(asbd.mBytesPerFrame)
        for index in 0..<Int(list.pointee.mNumberBuffers) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let data = buffers[index].mData, Int(buffers[index].mDataByteSize) > offset else { return nil }
            buffers[index].mData = data + offset
            buffers[index].mDataByteSize -= UInt32(offset)
        }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate.rounded())),
            presentationTimeStamp: pts, decodeTimeStamp: .invalid
        )
        var result: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: format, sampleCount: totalFrames - skip,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result
        ) == noErr, let result else { return nil }
        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            result, blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0, bufferList: list
        ) == noErr else { return nil }
        return result
    }

    /// Must be called with `lock` held.
    private func recordFailure() -> (String, @Sendable (String) -> Void)? {
        let message = writer.error?.localizedDescription ?? "append failed (status \(writer.status.rawValue))"
        failure = message
        Log.recording.error("writer failed: \(message, privacy: .public)")
        guard !failureReported, let onFailure else { return nil }
        failureReported = true
        return (message, onFailure)
    }

    // MARK: Finish

    /// Stops accepting samples (call before stopping the source so nothing
    /// after the stop moment gets in).
    func stopAccepting() {
        lock.withLock { acceptsSamples = false }
    }

    /// Refuses samples stamped at or after host `time` but keeps taking
    /// earlier ones still in flight (audio arrives a little after the video),
    /// until `finish`. Call before stopping the source.
    func stopAccepting(after time: CMTime) {
        lock.withLock { cutoff = time }
    }

    /// Ends the session at `stopTime` (host clock; clamped to the last frame)
    /// and finalizes the file. Throws `.noFrames` when no frame was written
    /// (the file is removed) and `.writerFailed` / `.finalizeFailed` on errors.
    func finish(at stopTime: CMTime) async throws -> RecordingWriterSummary {
        let (final, failed, retimer, lastFrame) = lock.withLock { () -> (RecordingWriterStats, String?, SampleRetimer, CMSampleBuffer?) in
            acceptsSamples = false
            heldFrame = nil
            let lastFrame = lastVideoSample
            lastVideoSample = nil
            return (self.stats, self.failure, self.retimer, lastFrame)
        }
        guard let start = final.sessionStart else {
            cancel()
            throw RecordingError.noFrames
        }
        if let failed {
            cancel()
            throw RecordingError.writerFailed(failed)
        }
        // Stopped while paused: the video ends at the pause start.
        var end = retimer.outputTime(forStopTime: stopTime)
        if let last = final.lastVideoTime, end < last { end = last }
        if end <= start { end = start + CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1))) }

        if let lastFrame, let last = final.lastVideoTime {
            await extendLastFrame(lastFrame, from: last, to: end)
        }
        writer.endSession(atSourceTime: end)
        videoInput.markAsFinished()
        for input in audioInputs.values { input.markAsFinished() }
        let writer = self.writer
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw RecordingError.finalizeFailed(writer.error?.localizedDescription ?? "finishWriting status \(writer.status.rawValue)")
        }
        return RecordingWriterSummary(
            sessionStart: start, sessionEnd: end,
            framesWritten: final.framesWritten, droppedFrames: final.droppedFrames,
            pauses: retimer.pauses(closingOpenPauseAt: stopTime, sessionStart: start),
            audioTracks: configuration.audioTracks.filter { (final.audioBuffersWritten[$0] ?? 0) > 0 }
        )
    }

    /// With audio tracks, `endSession` no longer stretches the last video
    /// sample to the session end (without audio it does), so a still screen
    /// (SCK sends no frames) would leave the video track ending early. The
    /// last frame is written once more, one frame before `end`, lasting
    /// until `end`.
    private func extendLastFrame(_ frame: CMSampleBuffer, from last: CMTime, to end: CMTime) async {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
        let pts = end - frameDuration
        guard pts > last else { return }
        var timing = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault, sampleBuffer: frame, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleBufferOut: &copy
        ) == noErr, let copy else { return }
        // Nothing else appends any more; wait briefly for the encoder.
        for _ in 0..<100 where !videoInput.isReadyForMoreMediaData {
            try? await Task.sleep(for: .milliseconds(5))
        }
        guard videoInput.isReadyForMoreMediaData, videoInput.append(copy) else {
            Log.recording.error("could not extend the last frame to the session end")
            return
        }
    }

    /// Abandons the file (discard / restart / failure) and deletes it.
    func cancel() {
        lock.withLock {
            acceptsSamples = false
            heldFrame = nil
            lastVideoSample = nil
            if writer.status == .writing { writer.cancelWriting() }
        }
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }
}

extension Log {
    nonisolated static let recording = Logger(subsystem: subsystem, category: "recording")
}
