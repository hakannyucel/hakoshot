@preconcurrency import AVFoundation
import Accelerate
import CoreMedia
import Foundation
import HakoKit
import os

/// Finalize with an audio mix (kayit-teknik-plan §4.14): video copied
/// sample by sample (passthrough, no re-encode), audio decoded to Float32
/// 48 kHz, mixed per `AudioMixPlan` and encoded to AAC. Used by
/// `RecordingFinalizer` only when the plan needs processing.
nonisolated enum AudioMixExporter {
    static let sampleRate = 48_000
    /// Frames per mixed AAC chunk (~85 ms).
    static let chunkFrames = 4_096

    /// Decoder output for analysis and mixing: interleaved Float32 at 48 kHz.
    static func pcmSettings(channelCount: Int) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    static func aacSettings(channelCount: Int, bitrate: Int) -> [String: Any] {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderBitRateKey: bitrate,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ]
    }

    /// Channel count of an audio track (1 or 2; more channels are read as 2).
    static func channelCount(of track: AVAssetTrack) async throws -> Int {
        let formats = try await track.load(.formatDescriptions)
        let channels = formats.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mChannelsPerFrame }
            .map(Int.init) ?? 2
        return min(2, max(1, channels))
    }

    // MARK: Analysis

    /// Whole-track peak per channel (linear), for the silent-channel fix.
    static func channelPeaks(of track: AVAssetTrack, in asset: AVAsset, channelCount: Int) async throws -> [Float] {
        try await runBlocking {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(channelCount: channelCount))
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw RecordingError.finalizeFailed("cannot read audio track") }
            reader.add(output)
            guard reader.startReading() else {
                throw RecordingError.finalizeFailed("audio analysis: \(reader.error?.localizedDescription ?? "unknown")")
            }
            var peaks = [Float](repeating: 0, count: channelCount)
            while let buffer = output.copyNextSampleBuffer() {
                let samples = interleavedSamples(of: buffer)
                let frames = samples.count / channelCount
                guard frames > 0 else { continue }
                samples.withUnsafeBufferPointer { pointer in
                    guard let base = pointer.baseAddress else { return }
                    for channel in 0..<channelCount {
                        var peak: Float = 0
                        vDSP_maxmgv(base + channel, vDSP_Stride(channelCount), &peak, vDSP_Length(frames))
                        peaks[channel] = max(peaks[channel], peak)
                    }
                }
            }
            if reader.status == .failed {
                throw RecordingError.finalizeFailed("audio analysis: \(reader.error?.localizedDescription ?? "unknown")")
            }
            return peaks
        }
    }

    // MARK: Export

    /// Writes `destination` (.mp4, replaced): the video track copied and the
    /// audio tracks mixed per `plan` (`audioTracks[i]` = `plan.inputs[i]`).
    static func export(
        asset: AVAsset,
        videoTrack: AVAssetTrack?,
        audioTracks: [AVAssetTrack],
        plan: AudioMixPlan,
        to destination: URL
    ) async throws {
        var videoFormat: CMFormatDescription?
        var transform = CGAffineTransform.identity
        if let videoTrack {
            let (formats, preferred) = try await videoTrack.load(.formatDescriptions, .preferredTransform)
            videoFormat = formats.first
            transform = preferred
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
        let job = try Job(
            asset: asset, videoTrack: videoTrack, videoFormat: videoFormat, transform: transform,
            audioTracks: audioTracks, plan: plan, destination: destination
        )
        do {
            try await runBlocking { try job.run() }
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }

    /// Runs blocking reader / writer work off the cooperative pool.
    private static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    /// One export: an `AVAssetReader` → `AVAssetWriter` loop on one thread.
    private final class Job: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoOutput: AVAssetReaderTrackOutput?
        let videoInput: AVAssetWriterInput?
        let streams: [PCMStream]
        let audioInputs: [AVAssetWriterInput]
        let plan: AudioMixPlan

        init(
            asset: AVAsset,
            videoTrack: AVAssetTrack?,
            videoFormat: CMFormatDescription?,
            transform: CGAffineTransform,
            audioTracks: [AVAssetTrack],
            plan: AudioMixPlan,
            destination: URL
        ) throws {
            self.plan = plan
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
            writer.shouldOptimizeForNetworkUse = true

            if let videoTrack {
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw RecordingError.finalizeFailed("cannot read video track") }
                reader.add(output)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
                input.expectsMediaDataInRealTime = false
                input.transform = transform
                guard writer.canAdd(input) else { throw RecordingError.finalizeFailed("cannot add video track") }
                writer.add(input)
                videoOutput = output
                videoInput = input
            } else {
                videoOutput = nil
                videoInput = nil
            }

            var streams: [PCMStream] = []
            for (index, track) in audioTracks.enumerated() {
                let channels = plan.inputs[index].channelCount
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings(channelCount: channels))
                output.alwaysCopiesSampleData = false
                guard reader.canAdd(output) else { throw RecordingError.finalizeFailed("cannot read audio track \(index)") }
                reader.add(output)
                streams.append(PCMStream(output: output, channelCount: channels))
            }
            self.streams = streams

            var inputs: [AVAssetWriterInput] = []
            for (index, track) in plan.outputs.enumerated() {
                let settings = aacSettings(channelCount: track.channelCount, bitrate: track.bitrate)
                guard writer.canApply(outputSettings: settings, forMediaType: .audio) else {
                    throw RecordingError.finalizeFailed("encoder rejected AAC \(track.channelCount) ch")
                }
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
                input.expectsMediaDataInRealTime = false
                guard writer.canAdd(input) else { throw RecordingError.finalizeFailed("cannot add audio track \(index)") }
                writer.add(input)
                inputs.append(input)
            }
            audioInputs = inputs
        }

        func run() throws {
            guard reader.startReading() else {
                throw RecordingError.finalizeFailed("reader: \(reader.error?.localizedDescription ?? "unknown")")
            }
            guard writer.startWriting() else {
                throw RecordingError.finalizeFailed("writer: \(writer.error?.localizedDescription ?? "unknown")")
            }
            defer { if reader.status == .reading { reader.cancelReading() } }

            // Media time 0 = the first video frame (the raw writer's T0);
            // audio is placed on a 48 kHz grid from there.
            var pendingVideo = videoOutput?.copyNextSampleBuffer()
            let origin = pendingVideo?.presentationTimeStamp ?? .zero
            writer.startSession(atSourceTime: origin)
            for stream in streams { stream.origin = origin }

            var videoDone = videoInput == nil || pendingVideo == nil
            if videoDone { videoInput?.markAsFinished() }
            var audioDone = audioInputs.isEmpty
            var position: Int64 = 0

            while !(videoDone && audioDone) {
                if writer.status == .failed {
                    throw RecordingError.finalizeFailed("writer: \(writer.error?.localizedDescription ?? "unknown")")
                }
                if reader.status == .failed {
                    throw RecordingError.finalizeFailed("reader: \(reader.error?.localizedDescription ?? "unknown")")
                }
                var progressed = false
                if !videoDone, let videoInput, videoInput.isReadyForMoreMediaData {
                    if pendingVideo == nil { pendingVideo = videoOutput?.copyNextSampleBuffer() }
                    if let buffer = pendingVideo {
                        guard videoInput.append(buffer) else {
                            throw RecordingError.finalizeFailed("video append: \(writer.error?.localizedDescription ?? "unknown")")
                        }
                        pendingVideo = nil
                    } else {
                        videoInput.markAsFinished()
                        videoDone = true
                    }
                    progressed = true
                }
                if !audioDone, audioInputs.allSatisfy(\.isReadyForMoreMediaData) {
                    let chunks = streams.map { $0.read(from: position, count: chunkFrames) }
                    let valid = chunks.map(\.valid).max() ?? 0
                    if valid == 0 {
                        audioInputs.forEach { $0.markAsFinished() }
                        audioDone = true
                    } else {
                        let pts = origin + CMTime(value: position, timescale: CMTimeScale(sampleRate))
                        for (output, input) in zip(plan.outputs, audioInputs) {
                            let mixed = output.render(inputs: chunks.map(\.samples), frameCount: valid)
                            let buffer = try AudioMixExporter.makeSampleBuffer(mixed, channelCount: output.channelCount, pts: pts)
                            guard input.append(buffer) else {
                                throw RecordingError.finalizeFailed("audio append: \(writer.error?.localizedDescription ?? "unknown")")
                            }
                        }
                        position += Int64(valid)
                    }
                    progressed = true
                }
                if !progressed { usleep(1_000) }
            }

            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            semaphore.wait()
            guard writer.status == .completed else {
                throw RecordingError.finalizeFailed("writer: \(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")")
            }
        }
    }

    /// Decoded PCM of one track, served on a frame grid from `origin`
    /// (gaps become silence, overlaps are dropped).
    private final class PCMStream: @unchecked Sendable {
        let output: AVAssetReaderTrackOutput
        let channelCount: Int
        var origin: CMTime = .zero
        /// Interleaved samples for frames `start ..< start + frames`.
        private var buffer: [Float] = []
        private var start: Int64 = 0
        private var exhausted = false

        init(output: AVAssetReaderTrackOutput, channelCount: Int) {
            self.output = output
            self.channelCount = channelCount
        }

        private var end: Int64 { start + Int64(buffer.count / channelCount) }

        /// `count` frames from `position` (zero-padded) and how many of them
        /// are before the track's end (`count` while more may come).
        func read(from position: Int64, count: Int) -> (samples: [Float], valid: Int) {
            while !exhausted, end < position + Int64(count) { pull() }
            if position > start {
                let drop = Int(min(position, end) - start)
                buffer.removeFirst(drop * channelCount)
                start += Int64(drop)
            }
            var samples = [Float](repeating: 0, count: count * channelCount)
            let available = Int(max(0, min(Int64(count), end - position)))
            let offset = Int(max(0, start - position))
            if available > offset {
                let frames = available - offset
                samples.replaceSubrange(offset * channelCount ..< available * channelCount, with: buffer[0 ..< frames * channelCount])
            }
            return (samples, exhausted ? available : count)
        }

        private func pull() {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                exhausted = true
                return
            }
            var samples = AudioMixExporter.interleavedSamples(of: sampleBuffer)
            guard !samples.isEmpty else { return }
            let seconds = (sampleBuffer.presentationTimeStamp - origin).seconds
            guard seconds.isFinite else { return }
            let first = Int64((seconds * Double(AudioMixExporter.sampleRate)).rounded())
            if buffer.isEmpty, end < first {
                start = first // nothing buffered: jump (the reader fills zeros)
            } else if first > end {
                buffer.append(contentsOf: repeatElement(0, count: Int(first - end) * channelCount))
            }
            if first < end {
                let overlap = Int(end - first) * channelCount
                guard overlap < samples.count else { return }
                samples.removeFirst(overlap)
            }
            buffer.append(contentsOf: samples)
        }
    }

    // MARK: Sample buffers

    /// The Float32 samples of an interleaved PCM buffer.
    static func interleavedSamples(of sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let block = sampleBuffer.dataBuffer else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        let count = length / MemoryLayout<Float>.size
        guard count > 0 else { return [] }
        var samples = [Float](repeating: 0, count: count)
        let status = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: raw.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? samples : []
    }

    /// An interleaved Float32 48 kHz sample buffer at `pts`.
    static func makeSampleBuffer(_ samples: [Float], channelCount: Int, pts: CMTime) throws -> CMSampleBuffer {
        let frames = samples.count / channelCount
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channelCount == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        var format: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: MemoryLayout<AudioChannelLayout>.size, layout: &layout,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        )
        guard status == noErr, let format else { throw RecordingError.finalizeFailed("PCM format (\(status))") }

        let byteCount = samples.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: byteCount, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { throw RecordingError.finalizeFailed("PCM block (\(status))") }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard status == kCMBlockBufferNoErr else { throw RecordingError.finalizeFailed("PCM copy (\(status))") }

        var sampleBuffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw RecordingError.finalizeFailed("PCM sample buffer (\(status))") }
        return sampleBuffer
    }
}
