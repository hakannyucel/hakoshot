@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R2.2: the finalizer's audio mix (single / separate tracks, mono, the
/// silent-channel fix) on raw .mov files generated here: an H.264 video
/// track plus AAC tracks with 440 Hz (microphone) / 880 Hz (system) tones.
@Suite("Recording finalize audio mix", .serialized)
struct RecordingAudioMixTests {
    nonisolated static let micHz = 440.0
    nonisolated static let systemHz = 880.0
    nonisolated static let seconds = 2.0

    /// One raw AAC track: a tone per channel (`nil` = digital silence).
    nonisolated struct TrackSpec: Sendable {
        var left: Double?
        var right: Double?
    }

    // MARK: Tests

    @Test(.timeLimit(.minutes(1)))
    func singleTrackMixesBothTonesIntoStereo() async throws {
        try await withRaw([TrackSpec(left: Self.micHz, right: Self.micHz), TrackSpec(left: Self.systemHz, right: Self.systemHz)]) { raw, out in
            let report = try await RecordingFinalizer.convert(raw, to: out, roles: [.microphone, .system], audio: .standard)
            #expect(report.mixed)
            let tracks = try await Self.analyze(out)
            #expect(tracks.count == 1)
            let track = try #require(tracks.first)
            #expect(track.channels.count == 2)
            for channel in track.channels {
                #expect(channel.hasTone(Self.micHz), "\(channel)")
                #expect(channel.hasTone(Self.systemHz), "\(channel)")
            }
            try await Self.expectVideoKept(raw: raw, out: out)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func separateKeepsTwoTracks() async throws {
        try await withRaw([TrackSpec(left: Self.micHz, right: Self.micHz), TrackSpec(left: Self.systemHz, right: Self.systemHz)]) { raw, out in
            let report = try await RecordingFinalizer.convert(raw, to: out, roles: [.microphone, .system], audio: AudioMixSettings(layout: .separate))
            #expect(!report.mixed) // nothing to change: fast remux
            let tracks = try await Self.analyze(out)
            #expect(tracks.map(\.channels.count) == [2, 2])
            #expect(tracks.first?.channels.allSatisfy { $0.hasTone(Self.micHz) && !$0.hasTone(Self.systemHz) } == true)
            #expect(tracks.last?.channels.allSatisfy { $0.hasTone(Self.systemHz) && !$0.hasTone(Self.micHz) } == true)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func monoGivesOneChannel() async throws {
        try await withRaw([TrackSpec(left: Self.micHz, right: Self.micHz), TrackSpec(left: Self.systemHz, right: Self.systemHz)]) { raw, out in
            try await RecordingFinalizer.convert(raw, to: out, roles: [.microphone, .system], audio: AudioMixSettings(mono: true))
            let tracks = try await Self.analyze(out)
            #expect(tracks.count == 1)
            #expect(tracks.first?.channels.count == 1)
            #expect(tracks.first?.channels.first.map { $0.hasTone(Self.micHz) && $0.hasTone(Self.systemHz) } == true)

            let separate = out.deletingLastPathComponent().appending(path: "separate-mono.mp4")
            try await RecordingFinalizer.convert(raw, to: separate, roles: [.microphone, .system], audio: AudioMixSettings(layout: .separate, mono: true))
            #expect(try await Self.analyze(separate).map(\.channels.count) == [1, 1])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func oneSidedMicrophoneFillsBothChannels() async throws {
        try await withRaw([TrackSpec(left: Self.micHz, right: nil)]) { raw, out in
            let report = try await RecordingFinalizer.convert(raw, to: out, roles: [.microphone], audio: .standard)
            #expect(report.mixed)
            #expect(report.plan.silentChannelFixes == [0: 0])
            let tracks = try await Self.analyze(out)
            #expect(tracks.count == 1)
            let channels = try #require(tracks.first?.channels)
            #expect(channels.count == 2)
            for channel in channels {
                #expect(channel.rmsDBFS > -30, "\(channel)")
                #expect(channel.hasTone(Self.micHz))
            }
        }
        // The same file as system audio is left alone (panned audio is legitimate).
        try await withRaw([TrackSpec(left: Self.systemHz, right: nil)]) { raw, out in
            let report = try await RecordingFinalizer.convert(raw, to: out, roles: [.system], audio: .standard)
            #expect(!report.mixed)
            let channels = try #require(try await Self.analyze(out).first?.channels)
            #expect(channels.count == 2)
            #expect(channels[1].rmsDBFS < -60)
        }
    }

    @Test func rolesFollowRawTracksOrDefault() {
        #expect(RecordingFinalizer.roles([.microphone, .system], trackCount: 2) == [.microphone, .system])
        #expect(RecordingFinalizer.roles([.microphone], trackCount: 1) == [.microphone])
        #expect(RecordingFinalizer.roles([], trackCount: 1) == [.system])
        #expect(RecordingFinalizer.roles([], trackCount: 2) == [.microphone, .system])
        #expect(RecordingFinalizer.roles([.system], trackCount: 0).isEmpty)
        var options = RecordingOptions.default
        options.monoAudio = true
        options.audioTrackLayout = .separate
        #expect(AudioMixSettings(options) == AudioMixSettings(layout: .separate, mono: true))
        #expect(AudioMixSettings(RecordingOptions.default) == .standard)
    }

    @Test func finalizeParametersParse() throws {
        func items(_ query: String) -> [URLQueryItem] { URLComponents(string: "x://y?\(query)")?.queryItems ?? [] }
        let parameters = try #require(RecordingAudioDebug.FinalizeParameters(queryItems: items("filepath=/tmp/a.mov&tracks=separate&mono=1&out=/tmp/b.mp4&kinds=mic")))
        #expect(parameters.file.path == "/tmp/a.mov")
        #expect(parameters.out.path == "/tmp/b.mp4")
        #expect(parameters.settings == AudioMixSettings(layout: .separate, mono: true))
        #expect(parameters.kinds == [.microphone])
        #expect(RecordingAudioDebug.FinalizeParameters(queryItems: items("filepath=/tmp/a.mov")) == nil)
        #expect(RecordingAudioDebug.FinalizeParameters(queryItems: items("filepath=/tmp/a.mov&out=/tmp/b.mp4&tracks=many")) == nil)
        let defaults = try #require(RecordingAudioDebug.FinalizeParameters(queryItems: items("filepath=/tmp/a.mov&out=/tmp/b.mp4")))
        #expect(defaults.settings == .standard && defaults.kinds.isEmpty)
    }

    // MARK: Fixture

    private func withRaw(_ tracks: [TrackSpec], _ body: (URL, URL) async throws -> Void) async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hako-mix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let raw = dir.appending(path: "screen.mov")
        try await Self.writeRaw(to: raw, tracks: tracks)
        try await body(raw, dir.appending(path: "out.mp4"))
    }

    private static func expectVideoKept(raw: URL, out: URL) async throws {
        let source = AVURLAsset(url: raw)
        let result = AVURLAsset(url: out)
        let sourceVideo = try #require(try await source.loadTracks(withMediaType: .video).first)
        let resultVideo = try #require(try await result.loadTracks(withMediaType: .video).first)
        #expect(try await resultVideo.load(.naturalSize) == (try await sourceVideo.load(.naturalSize)))
        let formats = try await resultVideo.load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264)
        let videoDuration = try await resultVideo.load(.timeRange).duration.seconds
        #expect(abs(videoDuration - seconds) < 0.1, "video \(videoDuration)")
        let audio = try #require(try await result.loadTracks(withMediaType: .audio).first)
        let audioDuration = try await audio.load(.timeRange).duration.seconds
        #expect(abs(audioDuration - videoDuration) < 0.05, "audio \(audioDuration) video \(videoDuration)")
        // MPEG-4 container, not QuickTime.
        let head = try FileHandle(forReadingFrom: out).read(upToCount: 12) ?? Data()
        #expect(String(decoding: head[8..<12], as: UTF8.self) != "qt  ")
    }

    /// Writes an H.264 + AAC .mov like the raw recorder (48 kHz stereo AAC).
    static func writeRaw(to url: URL, tracks: [TrackSpec]) async throws {
        try await Task.detached { try writeRawBlocking(to: url, tracks: tracks) }.value
    }

    nonisolated private static func writeRawBlocking(to url: URL, tracks: [TrackSpec]) throws {
        let fps = 30
        let width = 160
        let height = 90
        let sampleRate = 48_000
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        let audioInputs = tracks.map { _ in
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: AudioMixExporter.aacSettings(channelCount: 2, bitrate: 192_000))
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            return input
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        let frameCount = Int(seconds * Double(fps))
        let audioFrames = Int(seconds * Double(sampleRate))
        let chunk = 1_024
        var frame = 0
        var audioPositions = [Int](repeating: 0, count: tracks.count)
        while frame < frameCount || audioPositions.contains(where: { $0 < audioFrames }) {
            var progressed = false
            if frame < frameCount, video.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool {
                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
                guard let pixelBuffer else { throw CocoaError(.fileWriteUnknown) }
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
                    memset(base, Int32(frame * 7 % 255), CVPixelBufferGetDataSize(pixelBuffer))
                }
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps))) else {
                    throw writer.error ?? CocoaError(.fileWriteUnknown)
                }
                frame += 1
                progressed = true
                if frame == frameCount { video.markAsFinished() }
            }
            for (index, spec) in tracks.enumerated() where audioPositions[index] < audioFrames && audioInputs[index].isReadyForMoreMediaData {
                let start = audioPositions[index]
                let count = min(chunk, audioFrames - start)
                var samples = [Float](repeating: 0, count: count * 2)
                for i in 0..<count {
                    let t = Double(start + i) / Double(sampleRate)
                    if let hz = spec.left { samples[2 * i] = Float(0.3 * sin(2 * .pi * hz * t)) }
                    if let hz = spec.right { samples[2 * i + 1] = Float(0.3 * sin(2 * .pi * hz * t)) }
                }
                let buffer = try AudioMixExporter.makeSampleBuffer(samples, channelCount: 2, pts: CMTime(value: CMTimeValue(start), timescale: CMTimeScale(sampleRate)))
                guard audioInputs[index].append(buffer) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                audioPositions[index] += count
                if audioPositions[index] >= audioFrames { audioInputs[index].markAsFinished() }
                progressed = true
            }
            if !progressed { usleep(1_000) }
        }
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    // MARK: Analysis

    struct ChannelInfo: CustomStringConvertible {
        var rmsDBFS: Double
        /// Tone power relative to the channel's total power, per probe frequency.
        var toneShare: [Double: Double]

        func hasTone(_ hz: Double) -> Bool { (toneShare[hz] ?? 0) > 0.1 }

        var description: String {
            "rms \(String(format: "%.1f", rmsDBFS)) dB, " + toneShare.sorted { $0.key < $1.key }
                .map { "\(Int($0.key)) Hz \(String(format: "%.2f", $0.value))" }.joined(separator: ", ")
        }
    }

    struct TrackInfo {
        var channels: [ChannelInfo]
    }

    /// Per audio track and channel: RMS and single-bin DFT (Goertzel) power
    /// at 440 / 880 / 1234 Hz (control) over the middle second.
    static func analyze(_ url: URL) async throws -> [TrackInfo] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var infos: [TrackInfo] = []
        for track in tracks {
            let channels = try await AudioMixExporter.channelCount(of: track)
            let samples = try await Task.detached { () throws -> [Float] in
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: AudioMixExporter.pcmSettings(channelCount: channels))
                reader.add(output)
                reader.startReading()
                var all: [Float] = []
                while let buffer = output.copyNextSampleBuffer() { all += AudioMixExporter.interleavedSamples(of: buffer) }
                return all
            }.value
            let frames = samples.count / channels
            let window = 0.5 * seconds * 48_000
            let from = max(0, Int(Double(frames) / 2 - window / 2))
            let to = min(frames, from + Int(window))
            var channelInfos: [ChannelInfo] = []
            for channel in 0..<channels {
                let values = stride(from: from, to: to, by: 1).map { Double(samples[$0 * channels + channel]) }
                let power = values.reduce(0) { $0 + $1 * $1 } / Double(max(1, values.count))
                var shares: [Double: Double] = [:]
                for hz in [micHz, systemHz, 1_234] {
                    shares[hz] = power > 0 ? goertzelPower(values, hz: hz, sampleRate: 48_000) / power : 0
                }
                channelInfos.append(ChannelInfo(rmsDBFS: power > 0 ? 10 * log10(power) : -200, toneShare: shares))
            }
            infos.append(TrackInfo(channels: channelInfos))
        }
        return infos
    }

    /// Mean power of the `hz` component (a pure sine of amplitude A → A²/2).
    nonisolated static func goertzelPower(_ values: [Double], hz: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * hz / sampleRate
        let coefficient = 2 * cos(omega)
        var s1 = 0.0
        var s2 = 0.0
        for value in values {
            let s0 = value + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let magnitudeSquared = s1 * s1 + s2 * s2 - coefficient * s1 * s2
        let n = Double(values.count)
        return 2 * magnitudeSquared / (n * n)
    }
}
