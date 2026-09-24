import AVFoundation
import CoreMedia
import Foundation
import HakoKit
import os
import VideoToolbox

extension Log {
    nonisolated static let render = Logger(subsystem: subsystem, category: "render")
}

nonisolated enum RenderError: Error, Equatable, CustomStringConvertible {
    case noVideoTrack
    /// Trim/cuts leave nothing to render.
    case emptyTimeline
    case cannotRead(String)
    case cannotWrite(String)
    case gif(String)

    var description: String {
        switch self {
        case .noVideoTrack: "the source has no video track"
        case .emptyTimeline: "the edit leaves no video"
        case let .cannotRead(message): "reading failed: \(message)"
        case let .cannotWrite(message): "writing failed: \(message)"
        case let .gif(message): "GIF export failed: \(message)"
        }
    }
}

/// What the pipeline needs to know about a source file.
nonisolated struct RenderSourceInfo: Sendable, Equatable {
    var duration: Double
    /// Display size in pixels (after `preferredTransform`).
    var pixelWidth: Int
    var pixelHeight: Int
    /// Highest frame rate in the file (`1 / minFrameDuration`; screen
    /// recordings are VFR, so the nominal rate can be much lower).
    var fps: Double
    var nominalFPS: Double
    /// `nil` for codecs other than H.264/HEVC.
    var codec: VideoCodec?
    /// Channel count of every audio track, in file order.
    var audioChannelCounts: [Int]

    var audioTrackCount: Int { audioChannelCounts.count }
}

/// How one render will run (pure; unit-tested).
nonisolated struct RenderPlan: Sendable, Equatable {
    enum Mode: Sendable, Equatable {
        /// Trim/cut only: `AVAssetExportSession` passthrough, no re-encode.
        case passthrough
        /// Reader → custom compositor → hardware encoder.
        case reencode
        case gif
    }

    var mode: Mode
    var width: Int
    var height: Int
    var fps: Int
    /// Output codec (H.264 switches to HEVC above the H.264 size limit).
    var codec: VideoCodec
    var bitrate: Int
    var includesAudio: Bool
    /// 1 or 2 (re-encode only).
    var audioChannels: Int

    /// AAC bit rates (plan §1.3): stereo 128 kbps, mono 64 kbps.
    var audioBitrate: Int { audioChannels == 1 ? 64_000 : 128_000 }

    /// Above 4K30 pixel rate the encoder runs in speed-priority mode: the
    /// base M3 media engine encodes 4K60 HEVC at ~51 fps in its default
    /// mode (a 60 s 4K60 export would take ~70 s), ~80 fps with speed
    /// priority (R7.3 benchmark, plan §6 R7-4). Below that, quality mode.
    var prefersEncodingSpeed: Bool { width * height * fps > 3840 * 2160 * 30 }

    static func make(recipe: VideoEditRecipe, source: RenderSourceInfo, allowsPassthrough: Bool = true) -> RenderPlan {
        let recipe = recipe.normalized(sourceWidth: source.pixelWidth, sourceHeight: source.pixelHeight, sourceDuration: source.duration)
        let sourceFPS = Int(source.fps.rounded())
        if recipe.format == .gif {
            let size = recipe.gifOutputSize(sourceWidth: source.pixelWidth, sourceHeight: source.pixelHeight)
            return RenderPlan(
                mode: .gif, width: size.width, height: size.height, fps: recipe.gif.fps,
                codec: recipe.codec, bitrate: 0, includesAudio: false, audioChannels: 0
            )
        }
        let size = recipe.outputSize(sourceWidth: source.pixelWidth, sourceHeight: source.pixelHeight)
        let fps = recipe.outputFPS(sourceFPS: source.fps)
        var codec = recipe.codec
        if codec == .h264, !RecordingGeometry.fitsH264(width: size.width, height: size.height) { codec = .hevc }
        let includesAudio = !recipe.audio.muted && source.audioTrackCount > 0

        let videoUnchanged = recipe.crop == nil
            && size.width == source.pixelWidth && size.height == source.pixelHeight
            && (recipe.fps == nil || recipe.fps! >= sourceFPS)
            && source.codec == codec
        let audioUnchanged = recipe.audio.muted || recipe.audio.isUnchanged
        if allowsPassthrough, videoUnchanged, audioUnchanged {
            return RenderPlan(
                mode: .passthrough, width: size.width, height: size.height, fps: sourceFPS,
                codec: codec, bitrate: 0, includesAudio: includesAudio, audioChannels: 0
            )
        }
        let channels = recipe.audio.mono ? 1 : min(2, max(1, source.audioChannelCounts.max() ?? 2))
        return RenderPlan(
            mode: .reencode, width: size.width, height: size.height, fps: fps, codec: codec,
            bitrate: recipe.quality.bitrate(width: size.width, height: size.height, fps: fps, codec: codec),
            includesAudio: includesAudio, audioChannels: includesAudio ? channels : 0
        )
    }
}

/// Renders a `VideoEditRecipe` over a source video to MP4 or GIF
/// (kayit-teknik-plan §4.16, §4.17, §4.19).
///
/// - MP4, trim/cut only (plus mute): passthrough export, no re-encode.
/// - MP4 otherwise: `AVAssetReaderVideoCompositionOutput` (through
///   `StudioCompositor`: crop, scale, fps) + `AVAssetReaderAudioMixOutput`
///   (track gains, volume, mono) → `AVAssetWriter` (hardware H.264/HEVC,
///   bitrate from `VideoQuality`, AAC).
/// - GIF: `GIFExportJob`.
///
/// The file is written next to the destination under a hidden partial
/// name and moved into place only on success; cancelling the calling task
/// or a failure deletes it.
actor RenderPipeline {
    static let shared = RenderPipeline()

    /// `false` forces re-encoding even for trim-only edits.
    let allowsPassthrough: Bool

    init(allowsPassthrough: Bool = true) {
        self.allowsPassthrough = allowsPassthrough
    }

    /// Renders `source` with `recipe` to `destination` (replaced if it
    /// exists) and returns `destination`. `progress` gets increasing values
    /// in `0…1` from any thread, ending with 1.
    func render(
        source: URL,
        recipe: VideoEditRecipe,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let started = ContinuousClock.now
        let asset = AVURLAsset(url: source)
        let info = try await Self.probe(asset)
        let plan = RenderPlan.make(recipe: recipe, source: info, allowsPassthrough: allowsPassthrough)
        let output = RenderOutput(destination: destination)
        let reporter = RenderProgress(progress)
        try output.prepare()
        do {
            try Task.checkCancellation()
            switch plan.mode {
            case .gif:
                let composition = try await VideoCompositionBuilder.build(asset: asset, info: info, recipe: recipe, purpose: .gif)
                try await GIFExportJob.run(composition: composition, options: recipe.gif.normalized(), to: output.partial, progress: reporter)
            case .passthrough:
                let composition = try await VideoCompositionBuilder.build(asset: asset, info: info, recipe: recipe)
                try await Self.exportPassthrough(composition, to: output.partial, progress: reporter)
            case .reencode:
                let composition = try await VideoCompositionBuilder.build(asset: asset, info: info, recipe: recipe)
                let job = try ReencodeJob(composition: composition, plan: plan, url: output.partial, progress: reporter)
                try await job.run()
            }
            try Task.checkCancellation()
            try output.commit()
        } catch {
            output.discard()
            if error is CancellationError || Task.isCancelled {
                Log.render.notice("render cancelled: \(source.lastPathComponent, privacy: .public)")
                throw CancellationError()
            }
            Log.render.error("render failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        reporter.report(1)
        let elapsed = ContinuousClock.now - started
        Log.render.notice("rendered \(destination.lastPathComponent, privacy: .public) [\(String(describing: plan.mode), privacy: .public) \(plan.width)x\(plan.height)@\(plan.fps)] in \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))), privacy: .public)")
        return destination
    }

    // MARK: Probe

    static func probe(_ url: URL) async throws -> RenderSourceInfo {
        try await probe(AVURLAsset(url: url))
    }

    static func probe(_ asset: AVAsset) async throws -> RenderSourceInfo {
        let duration: Double
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            duration = try await asset.load(.duration).seconds
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw RenderError.cannotRead(error.localizedDescription)
        }
        guard let video = videoTracks.first else { throw RenderError.noVideoTrack }
        let (natural, transform, nominal, minFrame, formats) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .formatDescriptions
        )
        let size = natural.applying(transform)
        let nominalFPS = Double(nominal)
        var fps = minFrame.isValid && minFrame.seconds > 0 ? 1 / minFrame.seconds : nominalFPS
        if !(fps.isFinite && fps > 0) { fps = nominalFPS > 0 ? nominalFPS : 60 }
        let codec: VideoCodec? = switch formats.first.map(CMFormatDescriptionGetMediaSubType) {
        case kCMVideoCodecType_H264: .h264
        case kCMVideoCodecType_HEVC: .hevc
        default: nil
        }
        var channels: [Int] = []
        for track in audioTracks {
            let descriptions = (try? await track.load(.formatDescriptions)) ?? []
            let count = descriptions.first
                .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
                .map(Int.init) ?? 2
            channels.append(count)
        }
        return RenderSourceInfo(
            duration: duration.isFinite ? duration : 0,
            pixelWidth: Int(abs(size.width).rounded()),
            pixelHeight: Int(abs(size.height).rounded()),
            fps: fps,
            nominalFPS: nominalFPS,
            codec: codec,
            audioChannelCounts: channels
        )
    }

    // MARK: Passthrough

    private static func exportPassthrough(_ composition: RenderComposition, to url: URL, progress: RenderProgress) async throws {
        guard let session = AVAssetExportSession(asset: composition.composition, presetName: AVAssetExportPresetPassthrough) else {
            throw RenderError.cannotWrite("no passthrough export session")
        }
        session.shouldOptimizeForNetworkUse = true
        let states = session.states(updateInterval: 0.1)
        let monitor = Task {
            for await state in states {
                if case let .exporting(p) = state { progress.report(p.fractionCompleted * 0.99) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: url, as: .mp4)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RenderError.cannotWrite(error.localizedDescription)
        }
    }
}

// MARK: - Output file

/// The destination plus a hidden sibling the render writes first.
nonisolated struct RenderOutput: Sendable {
    let destination: URL
    let partial: URL

    init(destination: URL) {
        self.destination = destination
        let ext = destination.pathExtension.isEmpty ? "mp4" : destination.pathExtension
        let base = destination.deletingPathExtension().lastPathComponent
        let token = UUID().uuidString.prefix(8)
        partial = destination.deletingLastPathComponent().appending(path: ".\(base).partial-\(token).\(ext)")
    }

    func prepare() throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw RenderError.cannotWrite(error.localizedDescription)
        }
        try? fileManager.removeItem(at: partial)
    }

    func commit() throws {
        let fileManager = FileManager.default
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            discard()
            throw RenderError.cannotWrite(error.localizedDescription)
        }
    }

    /// Removes the partial file and any temporary siblings AVFoundation
    /// created for it (`AVAssetWriter` leaves `<partial>.sb-*` behind after
    /// `cancelWriting`).
    func discard() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: partial)
        let directory = partial.deletingLastPathComponent()
        let prefix = partial.lastPathComponent
        let siblings = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in siblings where name.hasPrefix(prefix) {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }
}

// MARK: - Progress

/// Forwards progress in `0…1`, only increasing (in steps of ≥ 0.2 %), from
/// any thread. The handler runs under a lock, so values arrive in order.
nonisolated final class RenderProgress: Sendable {
    private let handler: @Sendable (Double) -> Void
    private let last = OSAllocatedUnfairLock(initialState: -1.0)

    init(_ handler: @escaping @Sendable (Double) -> Void) {
        self.handler = handler
    }

    func report(_ value: Double) {
        guard value.isFinite else { return }
        let v = min(max(value, 0), 1)
        let handler = handler
        last.withLock { last in
            guard v > last + 0.002 || (v == 1 && last < 1) else { return }
            last = v
            handler(v)
        }
    }
}

// MARK: - Re-encode

/// One re-encoding run: composition reader → writer, pumped on two queues.
nonisolated final class ReencodeJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    private let audioProcessor: RenderAudioProcessor
    private let duration: CMTime
    private let progress: RenderProgress
    private let videoQueue = DispatchQueue(label: "com.hakanyucel.hakoshot.render.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.hakanyucel.hakoshot.render.audio", qos: .userInitiated)
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let failure = OSAllocatedUnfairLock<String?>(initialState: nil)
    /// Last time any pump appended a sample, plus the pumps' finish hooks,
    /// for the stall watchdog.
    private let activity = OSAllocatedUnfairLock(initialState: Activity())

    private struct Activity {
        var lastSample = ContinuousClock.now
        /// Keyed by `isVideo`; removed when that pump finishes.
        var finishers: [Bool: @Sendable () -> Void] = [:]
    }

    /// A pump that appends nothing for this long fails the job (a failed
    /// writer never calls `requestMediaDataWhenReady` blocks again).
    static let stallTimeout: Duration = .seconds(30)

    init(composition: RenderComposition, plan: RenderPlan, url: URL, progress: RenderProgress) throws {
        guard let videoTrack = composition.videoTrack, let videoComposition = composition.videoComposition else {
            throw RenderError.noVideoTrack
        }
        do {
            reader = try AVAssetReader(asset: composition.composition)
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw RenderError.cannotRead(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        duration = composition.composition.duration
        self.progress = progress

        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: Self.videoSettings(plan))
        videoInput.expectsMediaDataInRealTime = false

        audioProcessor = RenderAudioProcessor(gain: composition.postGain, mono: plan.audioChannels == 1)
        if plan.includesAudio, !composition.audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: composition.audioTracks, audioSettings: RenderAudioProcessor.readerSettings)
            output.audioMix = composition.audioMix
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: RenderAudioProcessor.sampleRate,
                AVNumberOfChannelsKey: plan.audioChannels,
                AVEncoderBitRateKey: plan.audioBitrate,
            ])
            input.expectsMediaDataInRealTime = false
            audioOutput = output
            audioInput = input
        } else {
            audioOutput = nil
            audioInput = nil
        }

        guard reader.canAdd(videoOutput), writer.canAdd(videoInput) else {
            throw RenderError.cannotWrite("video output/input rejected (\(plan.codec.rawValue) \(plan.width)x\(plan.height))")
        }
        reader.add(videoOutput)
        writer.add(videoInput)
        if let audioOutput, let audioInput {
            guard reader.canAdd(audioOutput), writer.canAdd(audioInput) else {
                throw RenderError.cannotWrite("audio output/input rejected")
            }
            reader.add(audioOutput)
            writer.add(audioInput)
        }
    }

    /// Hardware-preferred H.264 High / HEVC Main at the recipe bitrate,
    /// 2 s keyframes, BT.709 (plan §1.3, §4.19).
    static func videoSettings(_ plan: RenderPlan) -> [String: Any] {
        let profile: String = switch plan.codec {
        case .h264: AVVideoProfileLevelH264HighAutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: plan.bitrate,
            AVVideoExpectedSourceFrameRateKey: plan.fps,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoProfileLevelKey: profile,
        ]
        if plan.prefersEncodingSpeed {
            compression[kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality as String] = true
        }
        return [
            AVVideoCodecKey: plan.codec == .hevc ? AVVideoCodecType.hevc.rawValue : AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoEncoderSpecificationKey: [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            ],
        ]
    }

    func run() async throws {
        guard reader.startReading() else {
            throw RenderError.cannotRead(reader.error?.localizedDescription ?? "startReading")
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw RenderError.cannotWrite(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                pump(isVideo: true) { group.leave() }
                if audioOutput != nil, audioInput != nil {
                    group.enter()
                    pump(isVideo: false) { group.leave() }
                }
                group.notify(queue: .global(qos: .userInitiated)) { continuation.resume() }
                watch()
            }
        } onCancel: {
            cancel()
        }

        if cancelled.withLock({ $0 }) || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if let message = failure.withLock({ $0 }) {
            reader.cancelReading()
            writer.cancelWriting()
            throw RenderError.cannotWrite(message)
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw RenderError.cannotRead(reader.error?.localizedDescription ?? "reader failed")
        }
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.cannotWrite(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
    }

    func cancel() {
        cancelled.withLock { $0 = true }
        // The reader is cancelled only after both pumps drain. Cancelling
        // here can race copyNextSampleBuffer inside AVFoundation.
    }

    // MARK: Private

    /// Feeds one writer input from its reader output until the output is
    /// drained, the job is cancelled or appending fails.
    private func pump(isVideo: Bool, done: @escaping @Sendable () -> Void) {
        guard let input = isVideo ? videoInput : audioInput else { return done() }
        let queue = isVideo ? videoQueue : audioQueue
        let finished = OSAllocatedUnfairLock(initialState: false)
        let total = max(duration.seconds, 1e-3)
        let finish: @Sendable () -> Void = { [self] in
            guard finished.withLock({ was in defer { was = true }; return !was }) else { return }
            activity.withLock { _ = $0.finishers.removeValue(forKey: isVideo) }
            if writer.status == .writing, failure.withLock({ $0 == nil }) {
                (isVideo ? videoInput : audioInput)?.markAsFinished()
            }
            done()
        }
        // The watchdog must not finish an input or release the waiter while
        // its queue is still reading/appending a sample.
        activity.withLock { $0.finishers[isVideo] = { queue.async(execute: finish) } }
        input.requestMediaDataWhenReady(on: queue) { [self] in
            guard !finished.withLock({ $0 }) else { return }
            guard let input = isVideo ? videoInput : audioInput else { return finish() }
            while input.isReadyForMoreMediaData {
                if cancelled.withLock({ $0 }) || failure.withLock({ $0 != nil }) { return finish() }
                let next = isVideo ? videoOutput.copyNextSampleBuffer() : audioOutput?.copyNextSampleBuffer()
                guard var buffer = next else { return finish() }
                if !isVideo, audioProcessor.isActive {
                    guard let processed = audioProcessor.process(buffer) else {
                        fail("audio processing failed")
                        return finish()
                    }
                    buffer = processed
                }
                guard input.append(buffer) else {
                    fail(writer.error?.localizedDescription ?? "append failed")
                    return finish()
                }
                activity.withLock { $0.lastSample = .now }
                if isVideo {
                    let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    if pts.isFinite { progress.report(pts / total * 0.99) }
                }
            }
        }
    }

    /// Polls twice a second until every pump finished: a failed writer or
    /// a stall longer than `stallTimeout` fails the job and releases the
    /// pumps (as does a cancel that leaves a pump waiting for writer
    /// readiness). A read already in progress must return before its queue
    /// can finish; tearing down the reader concurrently is unsafe.
    private func watch() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
            let (finishers, idle) = activity.withLock { (Array($0.finishers.values), ContinuousClock.now - $0.lastSample) }
            guard !finishers.isEmpty else { return }
            if cancelled.withLock({ $0 }) {
                // Cancelled: an input that is not ready would never run
                // its block again, so release the pumps here.
                if idle > .seconds(1) { finishers.forEach { $0() } } else { watch() }
                return
            }
            let reason: String? = if writer.status == .failed {
                writer.error?.localizedDescription ?? "writer failed"
            } else if idle > Self.stallTimeout {
                "no progress for \(Self.stallTimeout)"
            } else {
                nil
            }
            guard let reason else { return watch() }
            fail(reason)
            finishers.forEach { $0() }
        }
    }

    private func fail(_ message: String) {
        failure.withLock { if $0 == nil { $0 = message } }
    }
}

// MARK: - Audio post-processing

/// Applies the post-mix gain (volume above 100 %) and the mono downmix to
/// interleaved Float32 PCM from `AVAssetReaderAudioMixOutput`.
nonisolated final class RenderAudioProcessor: @unchecked Sendable {
    static let sampleRate = 48_000.0

    /// Reader format: 48 kHz stereo interleaved Float32.
    static var readerSettings: [String: Any] {
        [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
        ]
    }

    let gain: Float
    let mono: Bool
    /// Only touched from the audio pump queue.
    private var monoFormat: CMAudioFormatDescription?

    init(gain: Double, mono: Bool) {
        self.gain = Float(gain.isFinite ? max(0, gain) : 1)
        self.mono = mono
    }

    var isActive: Bool { gain != 1 || mono }

    /// A new sample buffer with the gain (clipped to ±1) and, for mono, the
    /// channel average. Returns the input for formats it does not handle.
    func process(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(buffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              asbd.mBitsPerChannel == 32,
              let block = CMSampleBufferGetDataBuffer(buffer)
        else { return buffer }
        let channels = Int(asbd.mChannelsPerFrame)
        let frames = CMSampleBufferGetNumSamples(buffer)
        guard channels > 0, frames > 0 else { return buffer }

        var samples = [Float](repeating: 0, count: frames * channels)
        let copyStatus = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: min(raw.count, CMBlockBufferGetDataLength(block)), destination: raw.baseAddress!)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        let outChannels = mono ? 1 : channels
        var out: [Float]
        if mono && channels > 1 {
            out = [Float](repeating: 0, count: frames)
            let scale = gain / Float(channels)
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += samples[f * channels + c] }
                out[f] = min(max(sum * scale, -1), 1)
            }
        } else {
            out = samples
            if gain != 1 {
                for i in out.indices { out[i] = min(max(out[i] * gain, -1), 1) }
            }
        }

        let outFormat: CMAudioFormatDescription
        if outChannels == channels {
            outFormat = format
        } else if let monoFormat {
            outFormat = monoFormat
        } else {
            guard let made = Self.makeFormat(sampleRate: asbd.mSampleRate, channels: outChannels) else { return nil }
            monoFormat = made
            outFormat = made
        }
        return Self.makeSampleBuffer(out, frames: frames, format: outFormat, pts: CMSampleBufferGetPresentationTimeStamp(buffer))
    }

    static func makeFormat(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    private static func makeSampleBuffer(_ samples: [Float], frames: Int, format: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let replaced = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard replaced == kCMBlockBufferNoErr else { return nil }
        var buffer: CMSampleBuffer?
        let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil,
            sampleBufferOut: &buffer
        )
        return status == noErr ? buffer : nil
    }
}
