#if DEBUG
import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import HakoKit
import os

/// DEBUG helper for R0.4: seed history with one generated video entry,
/// exercising `HistoryStore.addRecording` end to end without a real screen
/// recording. Wiring this to a `debug-history-sample-video` URL (like
/// `HistoryDebug.launchArgument` wires screenshot samples) is left to R0.I
/// ("Entegrasyon parçası": `URLSchemeHandler` is a hotspot this package must
/// not touch).
extension HistoryDebug {
    private static let sampleVideoWidth = 640
    private static let sampleVideoHeight = 400
    private static let sampleVideoDuration = 2.0
    private static let sampleVideoFPS: Int32 = 24

    private enum SampleVideoError: Error {
        case noPixelBufferPool
        case writerFailed(String)
    }

    /// Generates a short synthetic mp4 (solid color, 2 s, no audio) with
    /// `AVAssetWriter` and adds it to `store` via `addRecording`. Returns the
    /// new entry, or `nil` on failure (logged).
    @discardableResult
    static func addSampleVideo(into store: HistoryStore = .shared) async -> HistoryItem? {
        let mediaURL: URL
        do {
            mediaURL = try await makeSyntheticVideo()
        } catch {
            Log.history.error("debug: addSampleVideo media generation failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        defer { try? FileManager.default.removeItem(at: mediaURL) }

        guard let thumbnail = sampleVideoThumbnail() else {
            Log.history.error("debug: addSampleVideo thumbnail generation failed")
            return nil
        }

        let result = RecordingResult(
            fileURL: mediaURL,
            format: .video,
            duration: sampleVideoDuration,
            pixelSize: CGSize(width: CGFloat(sampleVideoWidth), height: CGFloat(sampleVideoHeight)),
            thumbnail: thumbnail,
            targetKind: .area
        )
        let item = await store.addRecording(result)
        Log.history.notice("debug: addSampleVideo -> \(item?.id.uuidString ?? "nil", privacy: .public)")
        return item
    }

    /// Solid-color gradient thumbnail, independent of `sampleImage(...)`
    /// above (that one is `private` to `HistoryDebug.swift`, a different file).
    private static func sampleVideoThumbnail() -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: sampleVideoWidth, height: sampleVideoHeight, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        let top = NSColor(hue: 0.58, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor
        let bottom = NSColor(hue: 0.62, saturation: 0.8, brightness: 0.5, alpha: 1).cgColor
        if let gradient = CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: CGFloat(sampleVideoHeight)), end: .zero, options: []
            )
        }
        return ctx.makeImage()
    }

    /// Writes `sampleVideoDuration` seconds of a solid blue frame to a temp
    /// mp4, matching `sampleVideoWidth`×`sampleVideoHeight` at `sampleVideoFPS`.
    private static func makeSyntheticVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "hako-history-sample-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: sampleVideoWidth,
            AVVideoHeightKey: sampleVideoHeight,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: sampleVideoWidth,
            kCVPixelBufferHeightKey as String: sampleVideoHeight,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        writer.add(input)

        guard writer.startWriting() else {
            throw SampleVideoError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            throw SampleVideoError.noPixelBufferPool
        }

        let frameCount = max(1, Int(Double(sampleVideoFPS) * sampleVideoDuration))
        for frame in 0..<frameCount {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var pixelBufferOut: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
            guard let pixelBuffer = pixelBufferOut else { continue }
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            if let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: sampleVideoWidth,
                height: sampleVideoHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            ) {
                context.setFillColor(red: 0.25, green: 0.55, blue: 0.95, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: sampleVideoWidth, height: sampleVideoHeight))
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            let time = CMTime(value: CMTimeValue(frame), timescale: sampleVideoFPS)
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else {
                throw SampleVideoError.writerFailed(writer.error?.localizedDescription ?? "append frame \(frame) failed")
            }
        }
        input.markAsFinished()

        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw SampleVideoError.writerFailed(writer.error?.localizedDescription ?? "status: \(writer.status.rawValue)")
        }
        return url
    }
}
#endif
