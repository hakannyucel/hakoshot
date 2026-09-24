#!/usr/bin/env swift
// Generates small, deterministic sample media used to verify HakoShot's headless
// media-inspection scripts (media-info, frame-at, pixel-probe, audio-probe).
//
// Usage: swift scripts/make-test-media.swift <out-dir>
//
// Writes into <out-dir>:
//   - video.mp4  3.0 s, 1280x720, H.264 + AAC stereo audio.
//                Video is three 1 s solid-color segments (red / green / blue),
//                useful to sanity-check frame-at.swift + pixel-probe.swift.
//                Audio is a 440 Hz sine on the left channel and an 880 Hz sine
//                on the right channel, useful to sanity-check audio-probe.swift.
//   - test.gif   10 frames, 64x64, known per-frame delays (5,10,...,50 cs),
//                loop count 0, distinct solid colors per frame.
//
// System frameworks only; no package. Run directly with `swift <path>`.

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ScriptError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("make-test-media: \(message)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Argument parsing

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: swift scripts/make-test-media.swift <out-dir>")
}
let outDir = URL(fileURLWithPath: arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let videoURL = outDir.appendingPathComponent("video.mp4")
let gifURL = outDir.appendingPathComponent("test.gif")
try? FileManager.default.removeItem(at: videoURL)
try? FileManager.default.removeItem(at: gifURL)

// MARK: - Video + audio generation

let width = 1280
let height = 720
let fps: Int32 = 30
let durationSeconds = 3.0
let sampleRate = 48000.0

func makeVideoWriterInput() -> AVAssetWriterInput {
    let settings: [String: Any] = [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    return input
}

func makePixelBuffer(color: (r: CGFloat, g: CGFloat, b: CGFloat), pool: CVPixelBufferPool) -> CVPixelBuffer {
    var pixelBufferOut: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBufferOut)
    guard let pixelBuffer = pixelBufferOut else {
        fail("could not allocate pixel buffer")
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        )
    else {
        fail("could not create CGContext for frame")
    }
    context.setFillColor(red: color.r, green: color.g, blue: color.b, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return pixelBuffer
}

func makeAudioFormatDescription() -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 16,
        mReserved: 0
    )
    var formatDescription: CMAudioFormatDescription?
    let status = CMAudioFormatDescriptionCreate(
        allocator: kCFAllocatorDefault,
        asbd: &asbd,
        layoutSize: 0,
        layout: nil,
        magicCookieSize: 0,
        magicCookie: nil,
        extensions: nil,
        formatDescriptionOut: &formatDescription
    )
    guard status == noErr, let formatDescription else {
        fail("CMAudioFormatDescriptionCreate failed: \(status)")
    }
    return formatDescription
}

func makeAudioSampleBuffer(startFrame: Int, frameCount: Int, formatDescription: CMAudioFormatDescription) -> CMSampleBuffer {
    var samples = [Int16](repeating: 0, count: frameCount * 2)
    for i in 0..<frameCount {
        let t = Double(startFrame + i) / sampleRate
        let left = sin(2.0 * Double.pi * 440.0 * t)
        let right = sin(2.0 * Double.pi * 880.0 * t)
        samples[i * 2] = Int16((left * 0.8 * Double(Int16.max)).rounded())
        samples[i * 2 + 1] = Int16((right * 0.8 * Double(Int16.max)).rounded())
    }

    var blockBuffer: CMBlockBuffer?
    let byteCount = samples.count * MemoryLayout<Int16>.size
    let status = samples.withUnsafeMutableBytes { rawBuffer -> OSStatus in
        CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
    }
    guard status == noErr, let blockBuffer else {
        fail("CMBlockBufferCreateWithMemoryBlock failed: \(status)")
    }
    let copyStatus = samples.withUnsafeBytes { rawBuffer -> OSStatus in
        CMBlockBufferReplaceDataBytes(with: rawBuffer.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: byteCount)
    }
    guard copyStatus == noErr else {
        fail("CMBlockBufferReplaceDataBytes failed: \(copyStatus)")
    }

    var sampleBuffer: CMSampleBuffer?
    let presentationTime = CMTime(value: CMTimeValue(startFrame), timescale: CMTimeScale(sampleRate))
    let createStatus = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        allocator: kCFAllocatorDefault,
        dataBuffer: blockBuffer,
        formatDescription: formatDescription,
        sampleCount: frameCount,
        presentationTimeStamp: presentationTime,
        packetDescriptions: nil,
        sampleBufferOut: &sampleBuffer
    )
    guard createStatus == noErr, let sampleBuffer else {
        fail("CMAudioSampleBufferCreateReadyWithPacketDescriptions failed: \(createStatus)")
    }
    return sampleBuffer
}

func writeVideo() throws {
    let writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)

    let videoInput = makeVideoWriterInput()
    videoInput.expectsMediaDataInRealTime = false
    let pixelBufferAttributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelBufferAttributes)
    writer.add(videoInput)

    let audioFormatDescription = makeAudioFormatDescription()
    let audioSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ]
    let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormatDescription)
    audioInput.expectsMediaDataInRealTime = false
    writer.add(audioInput)

    guard writer.startWriting() else {
        fail("AVAssetWriter.startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)

    guard let pool = adaptor.pixelBufferPool else {
        fail("adaptor has no pixel buffer pool")
    }

    let totalFrames = Int(Double(fps) * durationSeconds)
    let colors: [(CGFloat, CGFloat, CGFloat)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
    let framesPerSegment = totalFrames / colors.count

    let videoQueue = DispatchQueue(label: "make-test-media.video")
    let videoDone = DispatchSemaphore(value: 0)
    var frameIndex = 0
    videoInput.requestMediaDataWhenReady(on: videoQueue) {
        while videoInput.isReadyForMoreMediaData, frameIndex < totalFrames {
            let segment = min(frameIndex / framesPerSegment, colors.count - 1)
            let pixelBuffer = makePixelBuffer(color: colors[segment], pool: pool)
            let pts = CMTime(value: CMTimeValue(frameIndex), timescale: fps)
            if !adaptor.append(pixelBuffer, withPresentationTime: pts) {
                fail("append video frame \(frameIndex) failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            frameIndex += 1
        }
        if frameIndex >= totalFrames {
            videoInput.markAsFinished()
            videoDone.signal()
        }
    }
    videoDone.wait()

    let totalAudioFrames = Int(sampleRate * durationSeconds)
    let chunkFrames = Int(sampleRate * 0.5) // 0.5 s chunks
    let audioQueue = DispatchQueue(label: "make-test-media.audio")
    let audioDone = DispatchSemaphore(value: 0)
    var startFrame = 0
    audioInput.requestMediaDataWhenReady(on: audioQueue) {
        while audioInput.isReadyForMoreMediaData, startFrame < totalAudioFrames {
            let count = min(chunkFrames, totalAudioFrames - startFrame)
            let sampleBuffer = makeAudioSampleBuffer(startFrame: startFrame, frameCount: count, formatDescription: audioFormatDescription)
            if !audioInput.append(sampleBuffer) {
                fail("append audio chunk at \(startFrame) failed: \(writer.error?.localizedDescription ?? "unknown")")
            }
            startFrame += count
        }
        if startFrame >= totalAudioFrames {
            audioInput.markAsFinished()
            audioDone.signal()
        }
    }
    audioDone.wait()

    let finishSemaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { finishSemaphore.signal() }
    finishSemaphore.wait()

    guard writer.status == .completed else {
        fail("writer finished with status \(writer.status.rawValue): \(writer.error?.localizedDescription ?? "unknown")")
    }
    print("wrote \(videoURL.path)")
}

// MARK: - GIF generation

func writeGIF() throws {
    let gifWidth = 64
    let gifHeight = 64
    let frameCount = 10
    let delaysCentiseconds = (1...frameCount).map { $0 * 5 } // 5,10,...,50

    guard
        let destination = CGImageDestinationCreateWithURL(gifURL as CFURL, UTType.gif.identifier as CFString, frameCount, nil)
    else {
        fail("could not create GIF destination")
    }

    let gifProperties: [CFString: Any] = [
        kCGImagePropertyGIFDictionary: [
            kCGImagePropertyGIFLoopCount: 0
        ]
    ]
    CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    for i in 0..<frameCount {
        let hue = Double(i) / Double(frameCount)
        let (r, g, b) = hsvToRGB(h: hue, s: 1, v: 1)
        guard
            let context = CGContext(
                data: nil,
                width: gifWidth,
                height: gifHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
            )
        else {
            fail("could not create GIF frame context")
        }
        context.setFillColor(red: r, green: g, blue: b, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: gifWidth, height: gifHeight))
        guard let cgImage = context.makeImage() else {
            fail("could not render GIF frame \(i)")
        }
        let delaySeconds = Double(delaysCentiseconds[i]) / 100.0
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delaySeconds,
                kCGImagePropertyGIFDelayTime: delaySeconds,
            ]
        ]
        CGImageDestinationAddImage(destination, cgImage, frameProperties as CFDictionary)
    }

    guard CGImageDestinationFinalize(destination) else {
        fail("CGImageDestinationFinalize failed for GIF")
    }
    print("wrote \(gifURL.path) delays(cs)=\(delaysCentiseconds)")
}

func hsvToRGB(h: Double, s: Double, v: Double) -> (CGFloat, CGFloat, CGFloat) {
    let i = Int(h * 6)
    let f = h * 6 - Double(i)
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)
    let (r, g, b): (Double, Double, Double)
    switch i % 6 {
    case 0: (r, g, b) = (v, t, p)
    case 1: (r, g, b) = (q, v, p)
    case 2: (r, g, b) = (p, v, t)
    case 3: (r, g, b) = (p, q, v)
    case 4: (r, g, b) = (t, p, v)
    default: (r, g, b) = (v, p, q)
    }
    return (CGFloat(r), CGFloat(g), CGFloat(b))
}

// MARK: - Run

try writeVideo()
try writeGIF()
