@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import os

/// Microphone through `AVCaptureSession`, used by `ScreenStreamSource` when
/// SCStream's `captureMicrophone` can't start (plan §1.4).
///
/// Delivers LPCM (float32, 48 kHz, stereo, via `audioSettings`) stamped on
/// the host clock: capture timestamps are on `session.synchronizationClock`
/// and are converted with `CMSyncConvertTime(→ host)`, so they line up with
/// the SCStream video frames.
///
/// Not exercised by the automated tests: opening the mic triggers the TCC
/// prompt for the user.
nonisolated final class MicrophoneCaptureFallback: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    // @unchecked: `session` / `handler` are set in start/stop (called
    // sequentially by the owning source) and read under `lock`.

    private let lock = NSLock()
    private var session: AVCaptureSession?
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    private let queue: DispatchQueue

    /// `queue`: where `handler` runs (the source's audio queue).
    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Opens `deviceID` (or the system default input) and starts delivering
    /// host-clock buffers to `handler`.
    func start(deviceID: String?, handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        let device = deviceID.flatMap(AVCaptureDevice.init(uniqueID:)) ?? AVCaptureDevice.default(for: .audio)
        guard let device else { throw RecordingError.sourceFailed("no microphone") }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecordingError.sourceFailed("microphone input: \(error.localizedDescription)")
        }
        let session = AVCaptureSession()
        session.beginConfiguration()
        guard session.canAddInput(input) else { throw RecordingError.sourceFailed("microphone: cannot add input") }
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw RecordingError.sourceFailed("microphone: cannot add output") }
        session.addOutput(output)
        session.commitConfiguration()
        lock.withLock {
            self.session = session
            self.handler = handler
        }
        session.startRunning()
        Log.recording.notice("microphone fallback (AVCaptureSession) started: \(device.localizedName, privacy: .public)")
    }

    func stop() {
        let session = lock.withLock { () -> AVCaptureSession? in
            let session = self.session
            self.session = nil
            self.handler = nil
            return session
        }
        session?.stopRunning()
    }

    // MARK: AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let (session, handler) = lock.withLock { (self.session, self.handler) }
        guard let session, let handler else { return }
        let pts = sampleBuffer.presentationTimeStamp
        guard pts.isValid else { return }
        let host = CMClockGetHostTimeClock()
        let hostPTS = session.synchronizationClock.map { CMSyncConvertTime(pts, from: $0, to: host) } ?? pts
        guard let converted = SampleRetimer.retimed(sampleBuffer, by: pts - hostPTS) else { return }
        handler(converted)
    }
}
