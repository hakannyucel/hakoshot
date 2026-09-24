import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import HakoKit
import os
@preconcurrency import ScreenCaptureKit

/// A stream frame: keeps the stream's pixel buffer and copies it into a
/// `CGImage` only when the stitcher needs it.
nonisolated struct PixelBufferFrame: ScrollingFrame, @unchecked Sendable {
    // CVPixelBuffer is immutable for us after delivery (read-only locks only).
    let buffer: CVPixelBuffer
    let time: TimeInterval
    let signature: FrameSignature

    func makeImage() -> CGImage? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: data as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

/// `SCStream` on the selection (plan §1.3): display filter without
/// HakoShot's own windows, `sourceRect` = selection, ~12 fps, no cursor,
/// BGRA in sRGB. Only frames whose status is `.complete` (content changed)
/// are passed on, with their row signature computed on the stream queue.
nonisolated final class ScrollingFrameSource: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    // @unchecked: `stream` is only touched in start/stop, which the session
    // calls sequentially; the callbacks only read immutable properties.
    static let framesPerSecond: Int32 = 12

    private let queue = DispatchQueue(label: "com.hakanyucel.HakoShot.scrolling-frames", qos: .userInitiated)
    private let trailingInset: Int
    private let onFrame: @Sendable (PixelBufferFrame) -> Void
    private let onStop: @Sendable (String) -> Void
    private var stream: SCStream?

    /// - Parameters:
    ///   - trailingInset: right-edge pixels ignored by the frame signature.
    ///   - onFrame: called on the stream queue, in order.
    ///   - onStop: the stream stopped with an error (display gone, permission revoked).
    init(
        trailingInset: Int,
        onFrame: @escaping @Sendable (PixelBufferFrame) -> Void,
        onStop: @escaping @Sendable (String) -> Void
    ) {
        self.trailingInset = trailingInset
        self.onFrame = onFrame
        self.onStop = onStop
    }

    /// - Parameters:
    ///   - sourceRect: region in the display's local points (top-left origin).
    ///   - pixelWidth/pixelHeight: output size (points × scale).
    func start(displayID: CGDirectDisplayID, sourceRect: CGRect, pixelWidth: Int, pixelHeight: Int) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == ownPID }
        let filter: SCContentFilter
        if ownApps.isEmpty {
            let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
            filter = SCContentFilter(display: display, excludingWindows: ownWindows)
        } else {
            // Excluding the app also covers panels created after this fetch.
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }

        let config = SCStreamConfiguration()
        config.sourceRect = sourceRect
        config.width = pixelWidth
        config.height = pixelHeight
        config.scalesToFit = false
        config.captureResolution = .best
        config.showsCursor = false
        config.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        // The engine holds one buffer (latest) plus a couple in flight.
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.scrolling.notice("stream started: display \(displayID) source \(String(describing: sourceRect), privacy: .public) -> \(pixelWidth)x\(pixelHeight) px")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        do {
            try await stream.stopCapture()
        } catch {
            Log.scrolling.debug("stopCapture: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus),
            status == .complete,
            let buffer = sampleBuffer.imageBuffer
        else { return }

        let time = ProcessInfo.processInfo.systemUptime
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let signature = FrameSignature.compute(
            base: UnsafeRawPointer(base),
            width: CVPixelBufferGetWidth(buffer),
            height: CVPixelBufferGetHeight(buffer),
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            trailingInset: trailingInset
        )
        onFrame(PixelBufferFrame(buffer: buffer, time: time, signature: signature))
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Log.scrolling.error("stream stopped: \(error.localizedDescription, privacy: .public)")
        onStop(error.localizedDescription)
    }
}
