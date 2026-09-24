import Accelerate
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HakoKit
import os

/// GIF export (kayit-teknik-plan §4.17): composition (trim, cuts, crop,
/// scale to the GIF width through `StudioCompositor`) → frames at the GIF
/// frame rate → `GIFFrameSampler` grid (6/7 cs delays at 15 fps) →
/// `GIFRepeatMerger` (identical consecutive frames) → `GIFEncoder` with a
/// global palette sampled from the clip (`optimize`) or per-frame palettes.
///
/// Also the "Convert to GIF" path for an existing video:
/// `GIFExportJob.export(source:options:to:progress:)`.
nonisolated enum GIFExportJob {
    /// Frames sampled for the global palette (plan §1.7: up to 32).
    static let paletteSampleCount = 24

    /// Converts a whole video to a GIF with `options` (Quick Access ⌘G,
    /// `convert-to-gif`). Same partial-file and cancellation rules as
    /// `RenderPipeline.render`.
    static func export(
        source: URL,
        options: GIFExportOptions = .default,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let recipe = VideoEditRecipe(format: .gif, gif: options)
        return try await RenderPipeline.shared.render(source: source, recipe: recipe, to: destination, progress: progress)
    }

    /// Writes the GIF for `composition` (built with purpose `.gif`) to `url`.
    /// Progress: palette sampling 0…0.1, frames 0.1…0.99.
    static func run(composition: RenderComposition, options: GIFExportOptions, to url: URL, progress: RenderProgress) async throws {
        guard let videoTrack = composition.videoTrack, let videoComposition = composition.videoComposition else {
            throw RenderError.noVideoTrack
        }
        let options = options.normalized()
        let sampler = GIFFrameSampler(fps: options.fps, duration: composition.duration)
        guard sampler.frameCount > 0 else { throw RenderError.emptyTimeline }

        let quantization: GIFQuantization
        if options.optimize {
            let samples = try await paletteSamples(composition, times: sampler.sampleTimes, progress: progress)
            quantization = GIFQuantization.forOptions(options, sampleFrames: samples)
        } else {
            quantization = .perFrame(maxColors: options.paletteColorCount, dither: options.ditherStrength)
        }
        try Task.checkCancellation()

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: composition.composition)
        } catch {
            throw RenderError.cannotRead(error.localizedDescription)
        }
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [videoTrack], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        output.videoComposition = videoComposition
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw RenderError.cannotRead("GIF reader output rejected") }
        reader.add(output)

        let job = FrameLoop(
            reader: reader, output: output, url: url, sampler: sampler,
            quantization: quantization, merges: options.optimize, progress: progress
        )
        try await withTaskCancellationHandler {
            try await job.run()
        } onCancel: {
            job.cancel()
        }
    }

    // MARK: Palette

    /// Up to `paletteSampleCount` frames spread over the clip.
    private static func paletteSamples(_ composition: RenderComposition, times: [Double], progress: RenderProgress) async throws -> [RGBAPixelBuffer] {
        let generator = AVAssetImageGenerator(asset: composition.composition)
        generator.videoComposition = composition.videoComposition
        let tolerance = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        let count = min(paletteSampleCount, times.count)
        var picks: [Double] = []
        for i in 0..<count {
            let index = count == 1 ? 0 : Int((Double(i) * Double(times.count - 1) / Double(count - 1)).rounded())
            picks.append(times[index])
        }
        var buffers: [RGBAPixelBuffer] = []
        for (i, time) in picks.enumerated() {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: VideoCompositionBuilder.cmTime(time)).image,
               let buffer = RGBAPixelBuffer(cgImage: image) {
                buffers.append(buffer)
            }
            progress.report(0.1 * Double(i + 1) / Double(count))
        }
        return buffers
    }

    // MARK: Repeat detection

    /// Repeat-merge key: equal when the content hashes match or when no
    /// channel differs by more than `tolerance`. Re-encoded keyframes add
    /// a little noise to still content, so an exact hash alone would keep
    /// "identical" frames apart; real changes (a moving cursor, typed text)
    /// differ far more.
    struct FrameKey: Equatable {
        static let tolerance: UInt8 = 10

        let hash: UInt64
        let buffer: RGBAPixelBuffer?

        init(_ buffer: RGBAPixelBuffer, hashed: Bool) {
            guard hashed else {
                hash = 0
                self.buffer = nil
                return
            }
            hash = buffer.pixels.withUnsafeBytes { raw in
                GIFFrameSampler.contentHash(bytes: raw, rowBytes: buffer.width * 4, bytesPerRow: buffer.width * 4, height: buffer.height)
            }
            self.buffer = buffer
        }

        static func == (a: FrameKey, b: FrameKey) -> Bool {
            if a.hash == b.hash { return true }
            guard let x = a.buffer, let y = b.buffer, x.width == y.width, x.height == y.height else { return false }
            return nearlyEqual(x.pixels, y.pixels, tolerance: tolerance)
        }

        static func nearlyEqual(_ a: [UInt8], _ b: [UInt8], tolerance: UInt8) -> Bool {
            guard a.count == b.count else { return false }
            return a.withUnsafeBufferPointer { pa in
                b.withUnsafeBufferPointer { pb in
                    var i = 0
                    let n = pa.count
                    while i < n {
                        let d = pa[i] > pb[i] ? pa[i] &- pb[i] : pb[i] &- pa[i]
                        if d > tolerance { return false }
                        i += 1
                    }
                    return true
                }
            }
        }
    }

    // MARK: Frame loop

    /// Reads composition frames on a private queue and feeds the encoder.
    /// `GIFEncoder` is not thread-safe, so every encoder call happens on
    /// that queue.
    private final class FrameLoop: @unchecked Sendable {
        private let reader: AVAssetReader
        private let output: AVAssetReaderVideoCompositionOutput
        private let url: URL
        private let sampler: GIFFrameSampler
        private let quantization: GIFQuantization
        private let merges: Bool
        private let progress: RenderProgress
        private let queue = DispatchQueue(label: "com.hakanyucel.hakoshot.render.gif", qos: .userInitiated)
        private let cancelled = OSAllocatedUnfairLock(initialState: false)

        init(
            reader: AVAssetReader, output: AVAssetReaderVideoCompositionOutput, url: URL,
            sampler: GIFFrameSampler, quantization: GIFQuantization, merges: Bool, progress: RenderProgress
        ) {
            self.reader = reader
            self.output = output
            self.url = url
            self.sampler = sampler
            self.quantization = quantization
            self.merges = merges
            self.progress = progress
        }

        func cancel() {
            cancelled.withLock { $0 = true }
            reader.cancelReading()
        }

        func run() async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    do {
                        try encodeAll()
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private var isCancelled: Bool { cancelled.withLock { $0 } }

        private func encodeAll() throws {
            let encoder: GIFEncoder
            do {
                encoder = try GIFEncoder(url: url, loopCount: 0, quantization: quantization)
            } catch {
                throw RenderError.gif("encoder: \(error)")
            }
            guard reader.startReading() else {
                encoder.discard()
                throw RenderError.cannotRead(reader.error?.localizedDescription ?? "startReading")
            }
            var merger = GIFRepeatMerger<RGBAPixelBuffer, FrameKey>()
            let times = sampler.sampleTimes
            let delays = sampler.delays
            var slot = 0
            var current: (buffer: RGBAPixelBuffer, key: FrameKey)?
            let epsilon = 1e-4

            func emit(_ frame: (buffer: RGBAPixelBuffer, key: FrameKey), delay: Int) throws {
                if merges {
                    if let ready = merger.add(frame.buffer, key: frame.key, delayCentiseconds: delay) {
                        try encoder.add(buffer: ready.frame, delayCentiseconds: ready.delayCentiseconds)
                    }
                } else {
                    try encoder.add(buffer: frame.buffer, delayCentiseconds: delay)
                }
                progress.report(0.1 + 0.89 * Double(slot + 1) / Double(times.count))
            }

            do {
                // Slot k shows the last frame whose time is ≤ its grid time
                // (GIFFrameSampler.sample semantics), streamed.
                while slot < times.count, !isCancelled {
                    guard let sample = autoreleasepool(invoking: { output.copyNextSampleBuffer() }) else { break }
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    if let frame = current {
                        while slot < times.count, times[slot] < t - epsilon {
                            try emit(frame, delay: delays[slot])
                            slot += 1
                        }
                    }
                    guard slot < times.count else { break }
                    guard let pixels = CMSampleBufferGetImageBuffer(sample), let buffer = Self.rgbaBuffer(from: pixels) else {
                        throw RenderError.gif("unreadable frame at \(t) s")
                    }
                    current = (buffer, FrameKey(buffer, hashed: merges))
                }
                if isCancelled { throw CancellationError() }
                if reader.status == .failed {
                    throw RenderError.cannotRead(reader.error?.localizedDescription ?? "reader failed")
                }
                guard let last = current else { throw RenderError.gif("no frames") }
                while slot < times.count {
                    try emit(last, delay: delays[slot])
                    slot += 1
                }
                if merges, let ready = merger.finish() {
                    try encoder.add(buffer: ready.frame, delayCentiseconds: ready.delayCentiseconds)
                }
                reader.cancelReading()
                try encoder.finalize()
            } catch let error as GIFEncoderError {
                reader.cancelReading()
                encoder.discard()
                throw RenderError.gif("\(error)")
            } catch {
                reader.cancelReading()
                encoder.discard()
                throw error
            }
        }

        /// BGRA pixel buffer → tightly packed RGBA (`vImagePermuteChannels`).
        static func rgbaBuffer(from pixelBuffer: CVPixelBuffer) -> RGBAPixelBuffer? {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
            let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
            guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            let error = pixels.withUnsafeMutableBytes { raw -> vImage_Error in
                var source = vImage_Buffer(
                    data: base, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: CVPixelBufferGetBytesPerRow(pixelBuffer)
                )
                var destination = vImage_Buffer(
                    data: raw.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width),
                    rowBytes: width * 4
                )
                let map: [UInt8] = [2, 1, 0, 3]
                return vImagePermuteChannels_ARGB8888(&source, &destination, map, vImage_Flags(kvImageNoFlags))
            }
            guard error == kvImageNoError else { return nil }
            return RGBAPixelBuffer(width: width, height: height, pixels: pixels)
        }
    }
}
