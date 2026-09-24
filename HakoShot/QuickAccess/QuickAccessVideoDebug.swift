#if DEBUG
import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// DEBUG helper for the video card (kayit-teknik-plan R0.5, `debug-quick-access-video-sample`):
/// writes a synthetic solid-color recording (no screen capture, no permission) and
/// shows it in Quick Access. Files go to `~/Library/Caches/HakoShot/DebugRecordings/`.
enum QuickAccessVideoDebug {
    private static let log = Logger(subsystem: "com.hakanyucel.HakoShot", category: "quick-access")

    enum SampleError: Error {
        case cannotCreate(String)
        case writerFailed(String)
    }

    /// Writes a sample (`seconds` long, `pixelSize`, one solid color) and shows its card
    /// on `controller` (default: the shared DEBUG controller). `format: .gif` writes a
    /// 2-frame-per-second GIF instead of an mp4. `hover` forces the hover controls on.
    /// Returns the card id, or `nil` if the file could not be written (logged).
    @discardableResult
    static func showSample(
        format: RecordingFormat = .video,
        seconds: Double = 2,
        pixelSize: CGSize = CGSize(width: 1280, height: 720),
        hover: Bool = false,
        on controller: QuickAccessController = QuickAccessDebug.controller
    ) async -> UUID? {
        do {
            let result = try await makeSampleResult(format: format, seconds: seconds, pixelSize: pixelSize)
            let id = controller.show(recording: result)
            if hover { controller.debugSetHovered(id) }
            log.notice("debug video card \(result.fileURL.path, privacy: .public)")
            return id
        } catch {
            log.error("debug video sample failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// A `RecordingResult` backed by a freshly written synthetic file.
    static func makeSampleResult(
        format: RecordingFormat = .video,
        seconds: Double = 2,
        pixelSize: CGSize = CGSize(width: 1280, height: 720),
        in directory: URL = sampleDirectory
    ) async throws -> RecordingResult {
        let width = Int(pixelSize.width)
        let height = Int(pixelSize.height)
        let color = (red: UInt8(0x2F), green: UInt8(0x7D), blue: UInt8(0xF6))
        let url = directory.appending(path: "sample-\(UUID().uuidString).\(format.pathExtension)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch format {
        case .video:
            try await writeSolidColorMP4(to: url, width: width, height: height, seconds: seconds, color: color)
        case .gif:
            try writeSolidColorGIF(to: url, width: width, height: height, seconds: seconds, color: color)
        }
        guard let thumbnail = solidImage(width: width, height: height, color: color) else {
            throw SampleError.cannotCreate("thumbnail")
        }
        return RecordingResult(
            fileURL: url,
            format: format,
            duration: seconds,
            pixelSize: pixelSize,
            thumbnail: thumbnail,
            targetKind: .area
        )
    }

    nonisolated static var sampleDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "HakoShot/DebugRecordings", directoryHint: .isDirectory)
    }

    // MARK: Writers

    /// H.264 mp4, 30 fps, every frame the same color.
    nonisolated static func writeSolidColorMP4(
        to url: URL,
        width: Int,
        height: Int,
        seconds: Double,
        color: (red: UInt8, green: UInt8, blue: UInt8),
        fps: Int32 = 30
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        guard writer.canAdd(input) else { throw SampleError.cannotCreate("writer input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw SampleError.writerFailed(writer.error.map { String(describing: $0) } ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        guard let buffer = solidPixelBuffer(width: width, height: height, color: color) else {
            throw SampleError.cannotCreate("pixel buffer")
        }
        let frameCount = max(1, Int((seconds * Double(fps)).rounded()))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw SampleError.writerFailed(writer.error.map { String(describing: $0) } ?? "append")
            }
        }
        input.markAsFinished()
        // Last frame lasts 1/fps, so the file is exactly `frameCount / fps` long.
        writer.endSession(atSourceTime: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw SampleError.writerFailed(writer.error.map { String(describing: $0) } ?? "finishWriting")
        }
    }

    /// Animated GIF, 2 frames per second, looping.
    nonisolated static func writeSolidColorGIF(
        to url: URL,
        width: Int,
        height: Int,
        seconds: Double,
        color: (red: UInt8, green: UInt8, blue: UInt8)
    ) throws {
        let frameCount = max(1, Int((seconds * 2).rounded()))
        guard let image = solidImage(width: width, height: height, color: color),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
        else { throw SampleError.cannotCreate("gif destination") }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5]] as CFDictionary
        for _ in 0..<frameCount {
            CGImageDestinationAddImage(destination, image, frameProperties)
        }
        guard CGImageDestinationFinalize(destination) else { throw SampleError.writerFailed("gif finalize") }
    }

    nonisolated private static func solidPixelBuffer(
        width: Int,
        height: Int,
        color: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
            for x in 0..<width {
                row[x * 4] = color.blue
                row[x * 4 + 1] = color.green
                row[x * 4 + 2] = color.red
                row[x * 4 + 3] = 0xFF
            }
        }
        return buffer
    }

    nonisolated private static func solidImage(
        width: Int,
        height: Int,
        color: (red: UInt8, green: UInt8, blue: UInt8)
    ) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { return nil }
        context.setFillColor(CGColor(
            srgbRed: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: 1
        ))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
#endif
