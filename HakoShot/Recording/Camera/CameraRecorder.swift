@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import HakoKit
import os

/// What `CameraRecorder.finish` wrote.
nonisolated struct CameraRecordingSummary: Sendable, Equatable {
    var url: URL
    /// Media duration (pauses removed), seconds.
    var duration: Double
    var pixelSize: CGSize
    /// Host seconds of the first written frame (camera media time 0).
    var firstFrameHostTime: Double
    var framesWritten: Int
    var framesDropped: Int
    /// Counted pauses, host seconds.
    var pauses: [ClosedRange<Double>]

    /// `RecordingMetadata.cameraTimeOffset` for a screen recording whose
    /// first frame (media time 0) was at host `screenOrigin`.
    func cameraTimeOffset(screenOrigin: Double) -> Double {
        CameraLayout.cameraTimeOffset(screenOrigin: screenOrigin, cameraOrigin: firstFrameHostTime)
    }
}

/// Writes the webcam to a separate `camera.mov` for the Studio profile
/// (plan §1.5, §4.8): H.264 High, the camera's resolution capped at 1080p
/// (short side), frames stamped on the host clock so
/// `RecordingMetadata.cameraTimeOffset` lines the file up with `screen.mov`.
///
/// Pause/resume mirror the screen writer (`SampleRetimer`): call them with
/// the same host instants as `RecordingEngine.pause/resume` and both files
/// drop the same host ranges, keeping the offset valid throughout.
///
/// Thread-safe (`NSLock`); `append` runs on the capture queue.
nonisolated final class CameraRecorder: @unchecked Sendable {
    struct Configuration: Sendable, Equatable {
        var outputURL: URL
        var maxResolution: RecordingResolutionCap = .p1080
        /// Nominal fps for the bitrate (webcams run ≈ 30).
        var fps: Int = 30
        var quality: VideoQuality = .high
    }

    let configuration: Configuration
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var retimer = SampleRetimer()
    private var firstHost: CMTime?
    /// Output PTS of the first frame (the writer session start).
    private var sessionStart: CMTime?
    private var lastOutputPTS: CMTime?
    private var pixelSize: CGSize = .zero
    private var written = 0
    private var dropped = 0
    private var accepting = true
    private var failure: String?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    convenience init(outputURL: URL) {
        self.init(configuration: Configuration(outputURL: outputURL))
    }

    /// Host seconds of the first written frame, once one arrived.
    var firstFrameHostTime: Double? { lock.withLock { firstHost?.seconds } }
    var framesWritten: Int { lock.withLock { written } }
    var isPaused: Bool { lock.withLock { retimer.isPaused } }

    /// Output pixel size for a camera frame of `width × height`: short side
    /// capped at the configured resolution, even dimensions, never upscaled.
    static func outputSize(width: Int, height: Int, cap: RecordingResolutionCap) -> (width: Int, height: Int) {
        RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: width, height: height), backingScale: 1, scaleTo1x: false, maxResolution: cap
        )
    }

    /// Connects to a capture: every camera frame goes to `append`.
    func attach(to capture: CameraCapture) {
        capture.setSampleHandler { [weak self] buffer, host in self?.append(buffer, hostTime: host) }
    }

    // MARK: Append

    /// Appends one camera frame whose PTS is `hostTime` (host clock).
    /// Frames inside a pause, before the writer is ready or after
    /// `finish` are dropped.
    func append(_ sampleBuffer: CMSampleBuffer, hostTime: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard accepting, failure == nil, let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let outputPTS = retimer.outputTime(forHostTime: hostTime) else { return }
        if let last = lastOutputPTS, outputPTS <= last { return }

        if writer == nil {
            do {
                try makeWriter(width: CVPixelBufferGetWidth(imageBuffer), height: CVPixelBufferGetHeight(imageBuffer))
            } catch {
                failure = String(describing: error)
                Log.camera.error("camera writer: \(String(describing: error), privacy: .public)")
                return
            }
        }
        guard let writer, let input else { return }
        if firstHost == nil {
            guard writer.startWriting() else {
                failure = writer.error?.localizedDescription ?? "startWriting failed"
                Log.camera.error("camera writer start: \(self.failure ?? "", privacy: .public)")
                return
            }
            writer.startSession(atSourceTime: outputPTS)
            firstHost = hostTime
            sessionStart = outputPTS
        }
        guard input.isReadyForMoreMediaData else {
            dropped += 1
            return
        }
        guard let stamped = SampleRetimer.restamped(sampleBuffer, at: outputPTS) else {
            dropped += 1
            return
        }
        if input.append(stamped) {
            written += 1
            lastOutputPTS = outputPTS
        } else {
            failure = writer.error?.localizedDescription ?? "append failed"
            Log.camera.error("camera append: \(self.failure ?? "", privacy: .public)")
        }
    }

    private func makeWriter(width: Int, height: Int) throws {
        let size = Self.outputSize(width: width, height: height, cap: configuration.maxResolution)
        try? FileManager.default.removeItem(at: configuration.outputURL)
        let writer = try AVAssetWriter(outputURL: configuration.outputURL, fileType: .mov)
        let bitrate = configuration.quality.bitrate(width: size.width, height: size.height, fps: configuration.fps, codec: .h264)
        var settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264.rawValue,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitrate,
                AVVideoExpectedSourceFrameRateKey: configuration.fps,
                AVVideoMaxKeyFrameIntervalDurationKey: 2.0,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ] as [String: Any],
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if size.width != width || size.height != height {
            settings[AVVideoScalingModeKey] = AVVideoScalingModeResizeAspectFill
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecordingError.writerFailed("camera input rejected") }
        writer.add(input)
        self.writer = writer
        self.input = input
        pixelSize = CGSize(width: size.width, height: size.height)
        Log.camera.notice("camera.mov \(size.width)x\(size.height) (source \(width)x\(height)), \(bitrate) bps")
    }

    // MARK: Pause

    func pause(at hostTime: CMTime) {
        lock.withLock { retimer.pause(at: hostTime) }
    }

    func resume(at hostTime: CMTime) {
        lock.withLock { _ = retimer.resume(at: hostTime, sessionStart: firstHost) }
    }

    // MARK: Finish

    /// Stops accepting frames and closes the file. `stopHostTime` (the
    /// screen's stop instant) ends the media there so both files have the
    /// same length; `nil` ends at the last frame. Throws `.noFrames` when
    /// nothing was written (the file is removed).
    func finish(at stopHostTime: CMTime? = nil) async throws -> CameraRecordingSummary {
        let state = lock.withLock { () -> (AVAssetWriter?, AVAssetWriterInput?, CMTime?, CMTime?, String?, Int) in
            accepting = false
            var end: CMTime?
            if let stopHostTime, let firstHost, stopHostTime > firstHost {
                end = retimer.outputTime(forStopTime: stopHostTime)
            }
            if let last = lastOutputPTS {
                let frame = CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
                let minimumEnd = last + frame
                if (end.map { $0 < minimumEnd }) ?? true { end = minimumEnd }
            }
            return (writer, input, sessionStart, end, failure, written)
        }
        guard let writer = state.0, let input = state.1, let start = state.2, let end = state.3, state.5 > 0 else {
            if state.0?.status == .writing { state.0?.cancelWriting() }
            try? FileManager.default.removeItem(at: configuration.outputURL)
            if let failure = state.4 { throw RecordingError.writerFailed(failure) }
            throw RecordingError.noFrames
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: end)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw RecordingError.finalizeFailed(writer.error?.localizedDescription ?? "camera finishWriting status \(writer.status.rawValue)")
        }
        return lock.withLock {
            CameraRecordingSummary(
                url: configuration.outputURL,
                duration: max((end - start).seconds, 0),
                pixelSize: pixelSize,
                firstFrameHostTime: firstHost?.seconds ?? start.seconds,
                framesWritten: written,
                framesDropped: dropped,
                pauses: retimer.pauses
            )
        }
    }

    /// Stops and deletes the file (discard / restart).
    func cancel() {
        let writer = lock.withLock { () -> AVAssetWriter? in
            accepting = false
            return self.writer
        }
        if writer?.status == .writing { writer?.cancelWriting() }
        try? FileManager.default.removeItem(at: configuration.outputURL)
    }
}
