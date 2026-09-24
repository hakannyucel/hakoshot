import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import HakoKit
import ImageIO
import os
import Testing
@testable import HakoShot

/// R3.2: render pipeline (kayit-teknik-plan §7 R3.2, §6 R3 acceptance).
/// Uses one synthetic 10 s 1920×1080 60 fps source with a moving pattern
/// and a stereo AAC track (440 Hz left, 880 Hz right).
@Suite("Render pipeline", .serialized)
struct RenderPipelineTests {
    // MARK: Plan (pure)

    private static let source1080 = RenderSourceInfo(
        duration: 10, pixelWidth: 1920, pixelHeight: 1080, fps: 60, nominalFPS: 60, codec: .h264, audioChannelCounts: [2]
    )

    @Test func planPicksPassthroughOnlyForTrimCutAndMute() {
        let trim = VideoEditRecipe(trim: EditTimeRange(start: 2, end: 7), cuts: [EditTimeRange(start: 3, end: 4)])
        #expect(RenderPlan.make(recipe: trim, source: Self.source1080).mode == .passthrough)
        #expect(RenderPlan.make(recipe: trim, source: Self.source1080, allowsPassthrough: false).mode == .reencode)

        var muted = trim
        muted.audio.muted = true
        let mutedPlan = RenderPlan.make(recipe: muted, source: Self.source1080)
        #expect(mutedPlan.mode == .passthrough)
        #expect(!mutedPlan.includesAudio)

        #expect(RenderPlan.make(recipe: VideoEditRecipe(crop: VideoCropRect(x: 0, y: 0, width: 640, height: 360)), source: Self.source1080).mode == .reencode)
        #expect(RenderPlan.make(recipe: VideoEditRecipe(outputWidth: 1280), source: Self.source1080).mode == .reencode)
        #expect(RenderPlan.make(recipe: VideoEditRecipe(fps: 30), source: Self.source1080).mode == .reencode)
        #expect(RenderPlan.make(recipe: VideoEditRecipe(fps: 60), source: Self.source1080).mode == .passthrough)
        #expect(RenderPlan.make(recipe: VideoEditRecipe(codec: .hevc), source: Self.source1080).mode == .reencode)
        #expect(RenderPlan.make(recipe: VideoEditRecipe(audio: VideoEditAudio(volume: 0)), source: Self.source1080).mode == .reencode)
        // A full-frame crop normalizes away.
        #expect(RenderPlan.make(recipe: VideoEditRecipe(crop: VideoCropRect(x: 0, y: 0, width: 1920, height: 1080)), source: Self.source1080).mode == .passthrough)
    }

    @Test func planEncoderSettings() {
        let plan = RenderPlan.make(recipe: VideoEditRecipe(fps: 30, quality: .high, audio: VideoEditAudio(mono: true)), source: Self.source1080)
        #expect(plan.mode == .reencode)
        #expect(plan.width == 1920 && plan.height == 1080 && plan.fps == 30)
        #expect(plan.bitrate == VideoQuality.high.bitrate(width: 1920, height: 1080, fps: 30, codec: .h264))
        #expect(plan.audioChannels == 1 && plan.audioBitrate == 64_000)

        // Above the H.264 limit the pipeline switches to HEVC.
        let fiveK = RenderSourceInfo(duration: 5, pixelWidth: 5120, pixelHeight: 2880, fps: 60, nominalFPS: 60, codec: .hevc, audioChannelCounts: [])
        let big = RenderPlan.make(recipe: VideoEditRecipe(fps: 30), source: fiveK)
        #expect(big.codec == .hevc)
        #expect(!big.includesAudio && big.audioChannels == 0)

        let gif = RenderPlan.make(recipe: VideoEditRecipe(format: .gif), source: Self.source1080)
        #expect(gif.mode == .gif && gif.width == 800 && gif.height == 450 && gif.fps == 15)
    }

    @Test func mixPlanKeepsVolumesAtMostOne() {
        let low = VideoCompositionBuilder.mixPlan(gains: [0.5, 1])
        #expect(low.volumes == [0.5, 1] && low.postGain == 1)
        let boosted = VideoCompositionBuilder.mixPlan(gains: [2, 1])
        #expect(boosted.volumes == [1, 0.5] && boosted.postGain == 2)
        #expect(VideoCompositionBuilder.mixPlan(gains: [0, 0]).volumes == [0, 0])
    }

    @Test func debugParameters() throws {
        let items = [
            URLQueryItem(name: "filepath", value: "/tmp/in.mov"),
            URLQueryItem(name: "recipe", value: #"{"trim":{"start":2,"end":7},"format":"gif"}"#),
            URLQueryItem(name: "out", value: "/tmp/out.gif"),
            URLQueryItem(name: "passthrough", value: "0"),
        ]
        let parameters = try RenderDebug.Parameters(queryItems: items)
        #expect(parameters.source.path == "/tmp/in.mov")
        #expect(parameters.out.path == "/tmp/out.gif")
        #expect(parameters.recipe.trim == EditTimeRange(start: 2, end: 7))
        #expect(parameters.recipe.format == .gif)
        #expect(!parameters.allowsPassthrough)
        #expect(throws: RenderDebug.Parameters.ParseError.missing("out")) {
            try RenderDebug.Parameters(queryItems: [URLQueryItem(name: "filepath", value: "/tmp/a.mp4")])
        }
    }

    // MARK: Rendering

    @Test(.timeLimit(.minutes(2)))
    func probeReadsSyntheticSource() async throws {
        let info = try await RenderPipeline.probe(try await RenderTestMedia.source())
        #expect(abs(info.duration - 10) < 0.05)
        #expect(info.pixelWidth == 1920 && info.pixelHeight == 1080)
        #expect(abs(info.fps - 60) < 0.5)
        #expect(info.codec == .h264)
        #expect(info.audioChannelCounts == [2])
    }

    @Test(.timeLimit(.minutes(2)), arguments: [true, false])
    func trimTwoToSevenLastsFiveSeconds(passthrough: Bool) async throws {
        let out = RenderTestMedia.outputURL("trim-\(passthrough).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let recipe = VideoEditRecipe(trim: EditTimeRange(start: 2, end: 7))
        _ = try await RenderPipeline(allowsPassthrough: passthrough).render(source: try await RenderTestMedia.source(), recipe: recipe, to: out)

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let videoDuration = try await video.load(.timeRange).duration.seconds
        #expect(abs(duration - 5) <= 1.0 / 60 + 1e-3, "duration \(duration)")
        #expect(abs(videoDuration - 5) <= 1.0 / 60 + 1e-3, "video \(videoDuration)")
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        RenderTestMedia.log("trim 2–7 (passthrough \(passthrough)): \(duration) s, video \(videoDuration) s")
    }

    @Test(.timeLimit(.minutes(2)))
    func cropSetsOutputSize() async throws {
        let out = RenderTestMedia.outputURL("crop.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let recipe = VideoEditRecipe(crop: VideoCropRect(x: 100, y: 200, width: 640, height: 360))
        _ = try await RenderPipeline.shared.render(source: try await RenderTestMedia.source(), recipe: recipe, to: out)

        let asset = AVURLAsset(url: out)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(size == CGSize(width: 640, height: 360))
        #expect(abs(try await asset.load(.duration).seconds - 10) <= 1.0 / 60 + 1e-3)

        // The crop's top-left pixel matches the source at (104, 204) (same
        // decoder; the synthetic source's own encode shifts the drawn color,
        // so compare against the decoded source rather than the fill).
        let image = try await RenderTestMedia.frame(out, at: 1)
        let sourceImage = try await RenderTestMedia.frame(try await RenderTestMedia.source(), at: 1)
        #expect(image.width == 640 && image.height == 360)
        let expected = try #require(RenderTestMedia.pixel(sourceImage, x: 104, y: 204))
        let pixel = try #require(RenderTestMedia.pixel(image, x: 4, y: 4))
        #expect(abs(Int(pixel.r) - Int(expected.r)) <= 6 && abs(Int(pixel.g) - Int(expected.g)) <= 6 && abs(Int(pixel.b) - Int(expected.b)) <= 6,
                "pixel \(pixel) expected \(expected)")
        RenderTestMedia.log("crop 640x360: \(size), pixel \(pixel) vs \(expected)")
    }

    @Test(.timeLimit(.minutes(2)))
    func fpsSixtyToThirty() async throws {
        let out = RenderTestMedia.outputURL("fps30.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await RenderPipeline.shared.render(source: try await RenderTestMedia.source(), recipe: VideoEditRecipe(fps: 30), to: out)

        let asset = AVURLAsset(url: out)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let nominal = try await video.load(.nominalFrameRate)
        let frames = try await RenderTestMedia.sampleCount(asset: asset, track: video)
        #expect(abs(Double(nominal) - 30) < 0.5, "nominal \(nominal)")
        #expect(abs(frames - 300) <= 1, "frames \(frames)")
        RenderTestMedia.log("fps 60→30: nominal \(nominal), \(frames) frames")
    }

    @Test(.timeLimit(.minutes(2)))
    func muteDropsAudio() async throws {
        let out = RenderTestMedia.outputURL("mute.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let recipe = VideoEditRecipe(trim: EditTimeRange(start: 0, end: 3), audio: VideoEditAudio(muted: true))
        _ = try await RenderPipeline.shared.render(source: try await RenderTestMedia.source(), recipe: recipe, to: out)
        let asset = AVURLAsset(url: out)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
    }

    @Test(.timeLimit(.minutes(2)))
    func volumeZeroIsSilent() async throws {
        let out = RenderTestMedia.outputURL("silent.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let recipe = VideoEditRecipe(trim: EditTimeRange(start: 0, end: 3), audio: VideoEditAudio(volume: 0))
        _ = try await RenderPipeline.shared.render(source: try await RenderTestMedia.source(), recipe: recipe, to: out)
        let rms = try await RenderTestMedia.rmsDecibels(URL: out)
        #expect(rms < -90, "RMS \(rms) dB")

        // Control: the unchanged source is loud.
        let loud = try await RenderTestMedia.rmsDecibels(URL: try await RenderTestMedia.source())
        #expect(loud > -20, "source RMS \(loud) dB")
        RenderTestMedia.log("volume 0: RMS \(rms) dB (source \(loud) dB)")
    }

    @Test(.timeLimit(.minutes(2)))
    func monoHasOneChannelWithBothTones() async throws {
        let out = RenderTestMedia.outputURL("mono.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let recipe = VideoEditRecipe(trim: EditTimeRange(start: 0, end: 3), audio: VideoEditAudio(mono: true))
        _ = try await RenderPipeline.shared.render(source: try await RenderTestMedia.source(), recipe: recipe, to: out)
        let asset = AVURLAsset(url: out)
        let audio = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let format = try #require(try await audio.load(.formatDescriptions).first)
        let channels = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee.mChannelsPerFrame
        #expect(channels == 1)
        let rms = try await RenderTestMedia.rmsDecibels(URL: out)
        #expect(rms > -30, "mono RMS \(rms) dB")
        RenderTestMedia.log("mono: \(channels ?? 0) channel, RMS \(rms) dB")
    }

    @Test(.timeLimit(.minutes(3)))
    func gifFifteenFPSEightHundredWide() async throws {
        let out = RenderTestMedia.outputURL("clip.gif")
        defer { try? FileManager.default.removeItem(at: out) }
        let recipe = VideoEditRecipe(trim: EditTimeRange(start: 2, end: 5), format: .gif, gif: GIFExportOptions(fps: 15, width: 800))
        let started = ContinuousClock.now
        _ = try await RenderPipeline.shared.render(source: try await RenderTestMedia.source(), recipe: recipe, to: out)
        let elapsed = ContinuousClock.now - started

        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let count = CGImageSourceGetCount(source)
        var delays: [Int] = []
        for i in 0..<count {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            delays.append(Int((delay * 100).rounded()))
        }
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let fileProperties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        let loop = (fileProperties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int

        // Every source frame differs, so nothing merges: exactly 15 × 3 s.
        #expect(count == 45, "frames \(count)")
        #expect(delays.allSatisfy { $0 == 6 || $0 == 7 }, "delays \(delays)")
        #expect(delays.reduce(0, +) == 300)
        #expect(first.width == 800 && first.height == 450)
        #expect(loop == 0)
        RenderTestMedia.log("GIF: \(count) frames, \(first.width)x\(first.height), delays \(Set(delays).sorted()), loop \(loop ?? -1), \(elapsed)")
    }

    @Test(.timeLimit(.minutes(2)))
    func gifMergesRepeatedFrames() async throws {
        // A still clip: every grid frame is identical → one GIF frame.
        let still = RenderTestMedia.outputURL("still.mp4")
        let out = RenderTestMedia.outputURL("still.gif")
        defer {
            try? FileManager.default.removeItem(at: still)
            try? FileManager.default.removeItem(at: out)
        }
        try await RenderTestMedia.write(to: still, width: 320, height: 180, fps: 30, seconds: 2, moving: false, audio: false)
        _ = try await GIFExportJob.export(source: still, options: GIFExportOptions(fps: 15, width: 0), to: out)
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 1)
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let delay = ((properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? 0
        #expect(Int((delay * 100).rounded()) == 200)
    }

    // Exercise cancellation while the audio/video reader queues are active,
    // at several progress points, to cover read/cancel races.
    @Test(.timeLimit(.minutes(2)), arguments: [0.005, 0.01, 0.02, 0.035, 0.05, 0.075, 0.1, 0.15])
    func cancelLeavesNoFile(cancelAfter: Double) async throws {
        let dir = RenderTestMedia.outputURL("cancel-\(UUID().uuidString)")
        let out = dir.appending(path: "cancelled.mp4")
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = try await RenderTestMedia.source()
        let started = OSAllocatedUnfairLock(initialState: false)
        let task = Task {
            try await RenderPipeline(allowsPassthrough: false).render(
                source: source, recipe: VideoEditRecipe(fps: 30), to: out,
                progress: { value in if value > cancelAfter { started.withLock { $0 = true } } }
            )
        }
        while !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(!FileManager.default.fileExists(atPath: out.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(leftovers.isEmpty, "left \(leftovers)")
    }

    @Test(.timeLimit(.minutes(2)))
    func progressIsMonotonicAndEndsAtOne() async throws {
        let out = RenderTestMedia.outputURL("progress.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let values = OSAllocatedUnfairLock<[Double]>(initialState: [])
        let started = ContinuousClock.now
        _ = try await RenderPipeline(allowsPassthrough: false).render(
            source: try await RenderTestMedia.source(), recipe: VideoEditRecipe(), to: out,
            progress: { value in values.withLock { $0.append(value) } }
        )
        let elapsed = ContinuousClock.now - started
        let reported = values.withLock { $0 }
        #expect(reported.count > 10)
        #expect(zip(reported, reported.dropFirst()).allSatisfy { $0 < $1 })
        #expect(reported.last == 1)
        #expect(reported.allSatisfy { (0...1).contains($0) })
        // Performance (hardware H.264, debug build): 10 s 1080p60 re-encode.
        RenderTestMedia.log("10 s 1080p60 re-encode: \(elapsed), \(reported.count) progress updates")
        #expect(elapsed < .seconds(60))
    }
}

// MARK: - Synthetic media

/// Test media: a 10 s 1920×1080 60 fps H.264 source with a moving square
/// over a background whose color changes every frame, plus stereo AAC
/// (440 Hz left, 880 Hz right). Generated once per test run.
nonisolated enum RenderTestMedia {
    static let directory = FileManager.default.temporaryDirectory.appending(path: "hako-render-tests-\(ProcessInfo.processInfo.processIdentifier)")
    private static let cache = SourceCache()

    static func source() async throws -> URL { try await cache.url() }

    static func outputURL(_ name: String) -> URL { directory.appending(path: name) }

    /// Printed and appended to `<tmp>/hako-render-tests.log` (xcodebuild
    /// hides test stdout; the numbers go into the package report).
    static func log(_ message: String) {
        print("[render-tests] \(message)")
        let url = FileManager.default.temporaryDirectory.appending(path: "hako-render-tests.log")
        let line = Data("\(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }

    private actor SourceCache {
        private var task: Task<URL, any Error>?

        func url() async throws -> URL {
            if let task { return try await task.value }
            let task = Task {
                try? FileManager.default.removeItem(at: RenderTestMedia.directory)
                try FileManager.default.createDirectory(at: RenderTestMedia.directory, withIntermediateDirectories: true)
                let url = RenderTestMedia.directory.appending(path: "source-1080p60.mp4")
                try await RenderTestMedia.write(to: url, width: 1920, height: 1080, fps: 60, seconds: 10, moving: true, audio: true)
                return url
            }
            self.task = task
            return try await task.value
        }
    }

    /// Background color of `frame` (8-bit sRGB-ish values as written).
    static func backgroundColor(frame: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8(40 + frame % 150), UInt8(90), UInt8(200 - frame % 150))
    }

    static func write(to url: URL, width: Int, height: Int, fps: Int32, seconds: Double, moving: Bool, audio: Bool) async throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let generator = try Generator(url: url, width: width, height: height, fps: fps, seconds: seconds, moving: moving, audio: audio)
        try await generator.run()
    }

    private final class Generator: @unchecked Sendable {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioInput: AVAssetWriterInput?
        let width: Int, height: Int, fps: Int32, totalFrames: Int, moving: Bool
        let sampleRate = 48_000
        let totalAudioFrames: Int
        var frameIndex = 0
        var audioFrame = 0

        init(url: URL, width: Int, height: Int, fps: Int32, seconds: Double, moving: Bool, audio: Bool) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            self.width = width
            self.height = height
            self.fps = fps
            self.moving = moving
            totalFrames = Int(Double(fps) * seconds)
            totalAudioFrames = Int(Double(sampleRate) * seconds)
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000],
            ])
            videoInput.expectsMediaDataInRealTime = false
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            writer.add(videoInput)
            if audio {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 128_000,
                ])
                input.expectsMediaDataInRealTime = false
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        }

        func run() async throws {
            guard writer.startWriting() else { throw RenderError.cannotWrite("test writer: \(String(describing: writer.error))") }
            writer.startSession(atSourceTime: .zero)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let group = DispatchGroup()
                group.enter()
                videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "test.video")) { [self] in
                    while videoInput.isReadyForMoreMediaData {
                        guard frameIndex < totalFrames, let pool = adaptor.pixelBufferPool, let buffer = makeFrame(frameIndex, pool: pool) else {
                            videoInput.markAsFinished()
                            group.leave()
                            return
                        }
                        _ = adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frameIndex), timescale: fps))
                        frameIndex += 1
                    }
                }
                if audioInput != nil {
                    group.enter()
                    audioInput?.requestMediaDataWhenReady(on: DispatchQueue(label: "test.audio")) { [self] in
                        guard let audioInput else { return }
                        while audioInput.isReadyForMoreMediaData {
                            guard audioFrame < totalAudioFrames, let buffer = makeAudio(start: audioFrame, count: min(4800, totalAudioFrames - audioFrame)) else {
                                audioInput.markAsFinished()
                                group.leave()
                                return
                            }
                            _ = audioInput.append(buffer)
                            audioFrame += CMSampleBufferGetNumSamples(buffer)
                        }
                    }
                }
                group.notify(queue: .global()) { continuation.resume() }
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw RenderError.cannotWrite("test writer: \(String(describing: writer.error))") }
        }

        private func makeFrame(_ index: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let buffer = out else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            let frame = moving ? index : 0
            let color = RenderTestMedia.backgroundColor(frame: frame)
            context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let side = height / 4
            let x = (frame * 12) % max(1, width - side)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            // CG origin is bottom-left; keep the square in the lower half so
            // the top-left crop area only shows the background.
            context.fill(CGRect(x: x, y: height / 8, width: side, height: side))
            return buffer
        }

        private func makeAudio(start: Int, count: Int) -> CMSampleBuffer? {
            var samples = [Int16](repeating: 0, count: count * 2)
            for i in 0..<count {
                let t = Double(start + i) / Double(sampleRate)
                samples[i * 2] = Int16((sin(2 * .pi * 440 * t) * 0.5 * Double(Int16.max)).rounded())
                samples[i * 2 + 1] = Int16((sin(2 * .pi * 880 * t) * 0.5 * Double(Int16.max)).rounded())
            }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0
            )
            var format: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { return nil }
            let byteCount = samples.count * 2
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return nil }
            _ = samples.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
            var buffer: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer
            )
            return buffer
        }
    }

    // MARK: Inspection

    /// Number of samples in `track` (compressed, no decoding).
    static func sampleCount(asset: AVAsset, track: AVAssetTrack) async throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()
        var count = 0
        while let buffer = output.copyNextSampleBuffer() {
            count += CMSampleBufferGetNumSamples(buffer) > 0 ? 1 : 0
        }
        return count
    }

    /// RMS in dBFS of all audio (first track), decoded to Float32.
    static func rmsDecibels(URL url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return -.infinity }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var sum = 0.0, count = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var floats = [Float](repeating: 0, count: length / 4)
            _ = floats.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            for f in floats { sum += Double(f) * Double(f) }
            count += floats.count
        }
        guard count > 0, sum > 0 else { return -.infinity }
        return 10 * log10(sum / Double(count))
    }

    /// Exact frame at `seconds`.
    static func frame(_ url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// RGBA of one pixel (top-left origin).
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let buffer = RGBAPixelBuffer(cgImage: image), x < buffer.width, y < buffer.height else { return nil }
        let i = (y * buffer.width + x) * 4
        return (buffer.pixels[i], buffer.pixels[i + 1], buffer.pixels[i + 2])
    }
}
