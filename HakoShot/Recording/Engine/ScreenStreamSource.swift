import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import HakoKit
import os
@preconcurrency import ScreenCaptureKit

/// `SCStream` frame source for recordings (plan §1.3, §4.5).
///
/// One display, `sourceRect` = recorded rect (display-local points), output
/// `pixelSize` from `RecordingOutputPlan`, 420v in BT.709 / sRGB,
/// `minimumFrameInterval = 1/fps`, `queueDepth 6`. Only `.complete` frames
/// (the screen changed) are delivered; `.idle` frames are dropped, which makes
/// the output variable-frame-rate.
///
/// Audio (plan §1.4, R2.1): system audio via `capturesAudio` (48 kHz stereo,
/// our own process excluded) → `onAudio(_, .system)`; microphone via
/// `captureMicrophone` + `microphoneCaptureDeviceID` → `onAudio(_, .microphone)`.
/// All buffers are on the host clock, like the video frames. If the stream
/// can't start with the microphone, it is restarted without it and the mic
/// comes from `MicrophoneCaptureFallback` (AVCaptureSession, converted to the
/// host clock).
nonisolated final class ScreenStreamSource: NSObject, RecordingFrameSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked: `stream`, `configuration` and `handlers` are written in
    // start/stop/updateSourceRect (called sequentially by the engine actor)
    // and read under `lock` from the SCK queues.

    static let queueDepth = 6

    private let videoQueue = DispatchQueue(label: "com.hakanyucel.HakoShot.recording.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "com.hakanyucel.HakoShot.recording.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var streamConfiguration: SCStreamConfiguration?
    private var handlers: RecordingFrameSourceHandlers?
    private var isStopping = false
    /// Window mode holds frames back until the stream has taken its first
    /// `sourceRect` update (`primeWindowRect`).
    private var holdsFrames = false
    /// Frames seen per status, for the log.
    private var completeFrames = 0
    private var idleFrames = 0

    /// Where the microphone comes from.
    enum MicrophonePath: String, Sendable, Equatable {
        /// SCStream `captureMicrophone`; AVCaptureSession if that fails.
        case automatic
        /// Always AVCaptureSession (`MicrophoneCaptureFallback`).
        case captureSession
    }

    /// Desktop icons / widgets are hidden in the video (`RecordingOptions.hideDesktopIcons`).
    let hidesDesktopIcons: Bool
    let microphonePath: MicrophonePath
    /// Set when the microphone runs through AVCaptureSession.
    private var microphoneFallback: MicrophoneCaptureFallback?
    /// The microphone path actually used by the running stream (logs, tests).
    private(set) var activeMicrophonePath: MicrophonePath?

    init(hidesDesktopIcons: Bool = false, microphonePath: MicrophonePath = .automatic) {
        self.hidesDesktopIcons = hidesDesktopIcons
        self.microphonePath = microphonePath
    }

    // MARK: RecordingFrameSource

    func start(_ configuration: RecordingSourceConfiguration, handlers: RecordingFrameSourceHandlers) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw RecordingError.permissionDenied(.screenRecording) }
        var microphoneDeviceID: String?
        if let microphone = configuration.microphone {
            // Never prompt from here: the HUD asks first (plan §1.8).
            guard MediaPermissions.microphone == .authorized else { throw RecordingError.permissionDenied(.microphone) }
            microphoneDeviceID = MicrophoneDeviceList.current().captureDeviceID(for: microphone)
        }
        let content: SCShareableContent
        do {
            content = try await ContentFilterBuilder.fetchContent()
        } catch {
            throw RecordingError.sourceFailed("shareable content: \(error.localizedDescription)")
        }
        let filter = try ContentFilterBuilder.makeFilter(
            ContentFilterBuilder.options(for: configuration, hidesDesktopIcons: hidesDesktopIcons),
            content: content
        )
        let windowID: CGWindowID? = if case let .window(id) = configuration.target { id } else { nil }
        lock.withLock {
            self.handlers = handlers
            self.isStopping = false
            self.holdsFrames = windowID != nil
        }

        let wantsMicrophone = configuration.microphone != nil
        if wantsMicrophone, microphonePath == .automatic {
            do {
                try await startStream(filter: filter, configuration: configuration, streamMicrophone: true, microphoneDeviceID: microphoneDeviceID)
                activeMicrophonePath = .automatic
                if let windowID { await primeWindowRect(windowID, configuration: configuration) }
                logStarted(configuration)
                return
            } catch {
                Log.recording.error("stream with captureMicrophone failed (\(error.localizedDescription, privacy: .public)); retrying with the AVCaptureSession microphone")
            }
        }
        do {
            try await startStream(filter: filter, configuration: configuration, streamMicrophone: false, microphoneDeviceID: nil)
            if wantsMicrophone {
                let fallback = MicrophoneCaptureFallback(queue: audioQueue)
                try fallback.start(deviceID: microphoneDeviceID) { [weak self] sampleBuffer in
                    guard let self else { return }
                    self.lock.withLock { self.isStopping ? nil : self.handlers }?.onAudio(sampleBuffer, .microphone)
                }
                lock.withLock { microphoneFallback = fallback }
                activeMicrophonePath = .captureSession
            }
        } catch {
            await stop()
            lock.withLock {
                self.handlers = nil
            }
            throw (error as? RecordingError) ?? RecordingError.sourceFailed(error.localizedDescription)
        }
        if let windowID { await primeWindowRect(windowID, configuration: configuration) }
        logStarted(configuration)
    }

    /// Window mode (R2.I fix): the first `updateConfiguration` of a stream
    /// with a window-including filter takes 0.2–0.7 s (later ones 40–100 ms),
    /// and frames delivered meanwhile show the window drifting inside the
    /// stale start rect (measured: shifted 120 pt under load). So the stream
    /// takes that first update right away, with the window's current rect,
    /// and only then starts delivering frames; `WindowFollower` then keeps up
    /// with fast updates.
    private func primeWindowRect(_ windowID: CGWindowID, configuration: RecordingSourceConfiguration) async {
        defer { lock.withLock { holdsFrames = false } }
        let bounds = CGDisplayBounds(configuration.displayID)
        guard let state = WindowFollower.liveWindowState(of: windowID), !bounds.isEmpty else { return }
        let placement = WindowFollowMath.placement(
            windowFrame: state.frame,
            displayFrame: GlobalRect(origin: bounds.origin, size: bounds.size),
            referenceSize: configuration.sourceRect?.size ?? state.frame.size
        )
        guard let rect = placement.sourceRect ?? configuration.sourceRect else { return }
        let started = CMClockGetTime(CMClockGetHostTimeClock())
        do {
            try await updateSourceRect(rect)
            let elapsed = (CMClockGetTime(CMClockGetHostTimeClock()) - started).seconds
            Log.recording.notice("window stream primed in \(Int(elapsed * 1000)) ms")
        } catch {
            Log.recording.error("window stream priming failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Creates and starts the stream; on failure nothing is left running.
    private func startStream(
        filter: SCContentFilter,
        configuration: RecordingSourceConfiguration,
        streamMicrophone: Bool,
        microphoneDeviceID: String?
    ) async throws {
        let config = Self.makeConfiguration(configuration, capturesMicrophone: streamMicrophone, microphoneDeviceID: microphoneDeviceID)
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
            if configuration.capturesSystemAudio {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            if streamMicrophone {
                try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)
            }
        } catch {
            throw RecordingError.sourceFailed("addStreamOutput: \(error.localizedDescription)")
        }
        lock.withLock {
            self.isStopping = false
            self.stream = stream
            self.streamConfiguration = config
        }
        do {
            try await stream.startCapture()
        } catch {
            lock.withLock {
                self.stream = nil
                self.streamConfiguration = nil
            }
            throw RecordingError.sourceFailed("startCapture: \(error.localizedDescription)")
        }
    }

    private func logStarted(_ configuration: RecordingSourceConfiguration) {
        let microphone = configuration.microphone == nil ? "off" : (activeMicrophonePath?.rawValue ?? "?")
        Log.recording.notice("stream started: display \(configuration.displayID) source \(String(describing: configuration.sourceRect), privacy: .public) -> \(Int(configuration.pixelSize.width))x\(Int(configuration.pixelSize.height)) px @\(configuration.fps) fps, cursor \(configuration.showsCursor), excepted \(configuration.exceptedWindowIDs.count), system audio \(configuration.capturesSystemAudio), mic \(microphone, privacy: .public)")
    }

    func updateSourceRect(_ rect: CGRect) async throws {
        let pair = lock.withLock { () -> (SCStream, SCStreamConfiguration)? in
            guard let stream, let streamConfiguration else { return nil }
            streamConfiguration.sourceRect = rect
            return (stream, streamConfiguration)
        }
        guard let (stream, config) = pair else { throw RecordingError.noActiveSession }
        do {
            try await stream.updateConfiguration(config)
        } catch {
            throw RecordingError.sourceFailed("updateConfiguration: \(error.localizedDescription)")
        }
    }

    func stop() async {
        let (stream, fallback) = lock.withLock { () -> (SCStream?, MicrophoneCaptureFallback?) in
            isStopping = true
            let stream = self.stream
            self.stream = nil
            let fallback = microphoneFallback
            microphoneFallback = nil
            return (stream, fallback)
        }
        fallback?.stop()
        guard let stream else { return }
        do {
            try await stream.stopCapture()
        } catch {
            Log.recording.debug("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
        // Drain callbacks already queued, then drop the handlers.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoQueue.async { continuation.resume() }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            audioQueue.async { continuation.resume() }
        }
        let counts = lock.withLock { () -> (Int, Int) in
            handlers = nil
            return (completeFrames, idleFrames)
        }
        Log.recording.notice("stream stopped: \(counts.0) complete / \(counts.1) idle frames")
    }

    // MARK: Configuration

    /// Stream settings from a source configuration (plan §1.3).
    /// Audio format of the stream's system audio (and what the writer's AAC
    /// tracks use).
    static let audioSampleRate = 48_000
    static let audioChannelCount = 2

    /// `capturesMicrophone`: SCStream records the mic (`nil` device = the
    /// system default input). Defaults: on when the configuration asks for a mic.
    static func makeConfiguration(
        _ configuration: RecordingSourceConfiguration,
        capturesMicrophone: Bool? = nil,
        microphoneDeviceID: String? = nil
    ) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = max(2, Int(configuration.pixelSize.width))
        config.height = max(2, Int(configuration.pixelSize.height))
        if let sourceRect = configuration.sourceRect { config.sourceRect = sourceRect }
        // The output size already has the rect's aspect ratio (even-floored);
        // scale the source rect onto it without letterboxing.
        config.scalesToFit = true
        config.preservesAspectRatio = false
        config.captureResolution = .best
        config.showsCursor = configuration.showsCursor
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(configuration.fps, 1)))
        config.queueDepth = queueDepth
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = kCVImageBufferYCbCrMatrix_ITU_R_709_2
        config.colorSpaceName = CGColorSpace.sRGB
        // Audio (plan §1.4).
        config.capturesAudio = configuration.capturesSystemAudio
        config.sampleRate = audioSampleRate
        config.channelCount = audioChannelCount
        config.excludesCurrentProcessAudio = true
        let microphone = capturesMicrophone ?? (configuration.microphone != nil)
        config.captureMicrophone = microphone
        config.microphoneCaptureDeviceID = microphone ? microphoneDeviceID : nil
        return config
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard let status = Self.frameStatus(of: sampleBuffer) else { return }
            let handlers = lock.withLock { () -> RecordingFrameSourceHandlers? in
                if status == .complete { completeFrames += 1 } else if status == .idle { idleFrames += 1 }
                return isStopping || holdsFrames ? nil : self.handlers
            }
            guard status == .complete, sampleBuffer.imageBuffer != nil, let handlers else { return }
            handlers.onVideo(sampleBuffer)
        case .audio:
            lock.withLock { isStopping ? nil : handlers }?.onAudio(sampleBuffer, .system)
        case .microphone:
            lock.withLock { isStopping ? nil : handlers }?.onAudio(sampleBuffer, .microphone)
        @unknown default:
            return
        }
    }

    static func frameStatus(of sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int
        else { return nil }
        return SCFrameStatus(rawValue: rawStatus)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        let handlers = lock.withLock { () -> RecordingFrameSourceHandlers? in
            guard !isStopping else { return nil }
            isStopping = true
            self.stream = nil
            return self.handlers
        }
        Log.recording.error("stream stopped with error: \(error.localizedDescription, privacy: .public)")
        handlers?.onStop(error)
    }
}
