@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import os

/// `AVCaptureSession` wrapper for the webcam (plan §1.5): one camera input,
/// a preview layer for the bubble and a sample-buffer stream (host-clock
/// timestamps) for `CameraRecorder`.
///
/// Never prompts: `start` throws `RecordingError.permissionDenied(.camera)`
/// unless the camera is already authorized (`CameraPermission.request()` is
/// the UI's job). Session work runs on a private serial queue; frames are
/// delivered on it too.
nonisolated final class CameraCapture: NSObject, @unchecked Sendable, AVCaptureVideoDataOutputSampleBufferDelegate {
    /// Frame handler: the buffer and its PTS on the host clock
    /// (`CMClockGetHostTimeClock`, same base as SCK and `HostTime`).
    typealias SampleHandler = @Sendable (CMSampleBuffer, CMTime) -> Void

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.hakanyucel.HakoShot.camera", qos: .userInitiated)
    private let output = AVCaptureVideoDataOutput()
    private let lock = NSLock()
    private var handler: SampleHandler?
    private var latestBuffer: CVPixelBuffer?
    private var framesDelivered = 0
    private(set) var device: AVCaptureDevice?

    override init() {
        super.init()
    }

    /// Frames delivered so far.
    var frameCount: Int { lock.withLock { framesDelivered } }

    /// Replaces the frame handler (`nil` stops delivery).
    func setSampleHandler(_ handler: SampleHandler?) {
        lock.withLock { self.handler = handler }
    }

    var isRunning: Bool { session.isRunning }

    /// Pixel size of the frames the output delivers (active format), if known.
    var frameSize: CGSize? {
        guard let device else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        return CGSize(width: Int(dims.width), height: Int(dims.height))
    }

    /// Opens `deviceID` (`nil` / "" = system preferred camera) and starts the
    /// session. Throws `.permissionDenied(.camera)` when not authorized and
    /// `.sourceFailed` when no camera exists or the input can't be added.
    func start(deviceID: String?) async throws {
        try CameraPermission.requireAuthorized()
        guard let device = CameraDeviceList.captureDevice(for: deviceID) else {
            throw RecordingError.sourceFailed("no camera connected")
        }
        let session = session
        let output = output
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    try configure(session: session, output: output, device: device)
                    session.startRunning()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        lock.withLock { self.device = device }
        Log.camera.notice("camera started: \(device.localizedName, privacy: .public) \(Int(self.frameSize?.width ?? 0))x\(Int(self.frameSize?.height ?? 0))")
    }

    private func configure(session: AVCaptureSession, output: AVCaptureVideoDataOutput, device: AVCaptureDevice) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for existing in session.outputs { session.removeOutput(existing) }
        // Plan §1.5: `.high` (≈ 720p on most webcams); CameraRecorder caps at 1080p.
        if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.sourceFailed("camera input: \(error.localizedDescription)")
        }
        guard session.canAddInput(input) else { throw RecordingError.sourceFailed("camera input rejected") }
        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordingError.sourceFailed("camera output rejected") }
        session.addOutput(output)
    }

    /// Stops the session (idempotent). The handler stays set.
    func stop() async {
        let session = session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
        }
    }

    /// A live preview for the bubble (aspect fill; mirroring is the bubble's job).
    @MainActor
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        return layer
    }

    /// The last delivered frame as a `CGImage` (debug snapshots).
    func latestFrameImage() -> CGImage? {
        guard let buffer = lock.withLock({ latestBuffer }) else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        return CIContext(options: [.cacheIntermediates: false]).createCGImage(image, from: image.extent)
    }

    // MARK: Clock

    /// `pts` (session clock) converted to the host clock.
    func hostTime(for pts: CMTime) -> CMTime {
        guard let clock = session.synchronizationClock else { return pts }
        return CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let host = hostTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let handler = lock.withLock { () -> SampleHandler? in
            latestBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
            framesDelivered += 1
            return self.handler
        }
        handler?(sampleBuffer, host)
    }
}
