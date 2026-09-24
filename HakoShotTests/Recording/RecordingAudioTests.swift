import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Audio capture (plan §1.4, §4.7, §7 R2.1): synthetic tones through the
/// engine and writer, level meter math, pause with audio, real system audio.
/// The microphone is never opened here (first use shows a TCC prompt).
@Suite("Recording audio", .serialized)
struct RecordingAudioTests {
    static func syntheticRequest(system: Bool, microphone: Bool, format: RecordingFormat = .video) -> RecordingRequest {
        var options = RecordingOptions.default
        options.capturesSystemAudio = system
        options.microphone = microphone ? .systemDefault : nil
        return RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 640, height: 360), displayID: CGMainDisplayID()),
            options: options, format: format, source: .synthetic
        )
    }

    // MARK: Synthetic tones → two AAC tracks

    /// Both sources on → the raw .mov has 2 AAC tracks (mic 880 Hz first,
    /// system 440 Hz second), 48 kHz stereo, each within ±50 ms of the video.
    @Test(.timeLimit(.minutes(1)))
    func syntheticBothSourcesWriteTwoAACTracks() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        _ = try await engine.start(Self.syntheticRequest(system: true, microphone: true))
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(1.5))
        let live = await engine.stats
        try await Task.sleep(for: .seconds(1.5))
        #expect(await !engine.isMicrophoneSilent)
        let raw = try await engine.stop()

        // Live levels: tone peak 0.25.
        let micLevel = try #require(live.microphoneLevel)
        let systemLevel = try #require(live.systemAudioLevel)
        #expect(abs(micLevel - SyntheticFrameSource.toneAmplitude) < 0.02, "mic level \(micLevel)")
        #expect(abs(systemLevel - SyntheticFrameSource.toneAmplitude) < 0.02, "system level \(systemLevel)")

        #expect(raw.audioTracks == [.microphone, .system])
        let tracks = try await Self.audioTracks(of: raw.screenURL)
        #expect(tracks.count == 2)
        let video = try await Self.videoRange(of: raw.screenURL)
        for (index, track) in tracks.enumerated() {
            RecordingSpikeTests.log("audio track \(index): \(track.summary), video \(video.start)…\(video.end)")
            #expect(track.codec == "aac ")
            #expect(track.sampleRate == 48_000)
            #expect(track.channels == 2)
            #expect(abs(track.duration - (video.end - video.start)) <= 0.05, "track \(index) \(track.duration) vs video \(video.end - video.start)")
            #expect(abs(track.start - video.start) <= 0.05, "track \(index) starts at \(track.start)")
        }
        let micFrequency = try await Self.dominantFrequency(url: raw.screenURL, trackIndex: 0)
        let systemFrequency = try await Self.dominantFrequency(url: raw.screenURL, trackIndex: 1)
        RecordingSpikeTests.log("dominant: mic \(micFrequency) Hz, system \(systemFrequency) Hz")
        #expect(abs(micFrequency - 880) <= 5, "mic \(micFrequency)")
        #expect(abs(systemFrequency - 440) <= 5, "system \(systemFrequency)")
        let rms = try await Self.rmsDBFS(url: raw.screenURL, trackIndex: 1)
        // 0.25 sine → −15.05 dBFS RMS (AAC keeps it within a dB).
        #expect(abs(rms - -15.05) < 1.5, "system rms \(rms)")
    }

    /// Only system audio → one track; GIF recordings get no audio.
    @Test(.timeLimit(.minutes(1)))
    func syntheticSystemOnlyAndGIF() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        let raw = try await RecordingEngineTests.record(engine, Self.syntheticRequest(system: true, microphone: false), seconds: 1)
        #expect(raw.audioTracks == [.system])
        #expect(try await Self.audioTracks(of: raw.screenURL).count == 1)
        #expect(try await Self.dominantFrequency(url: raw.screenURL, trackIndex: 0).distance(to: 440).magnitude <= 5)

        #expect(RecordingEngine.audioTracks(Self.syntheticRequest(system: true, microphone: true, format: .gif)) == [])
        #expect(RecordingEngine.audioTracks(Self.syntheticRequest(system: true, microphone: true)) == [.microphone, .system])
        #expect(RecordingWriterConfiguration.ordered([.system, .microphone, .system]) == [.microphone, .system])
    }

    // MARK: Pause with audio

    /// 2 s + 1 s pause + 2 s with both tones: the file matches the host-clock
    /// expectation and the audio tracks match the video (±50 ms).
    @Test(.timeLimit(.minutes(1)))
    func pauseWithAudioKeepsDurationsConsistent() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        _ = try await engine.start(Self.syntheticRequest(system: true, microphone: true))
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(2))
        try await engine.pause()
        try await Task.sleep(for: .seconds(1))
        try await engine.resume()
        try await Task.sleep(for: .seconds(2))
        let beforeStop = RecordingEngine.hostNow().seconds
        let raw = try await engine.stop()

        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: try #require(raw.eventsURL)))
        let pause = try #require(metadata.pauses.first)
        let expected = (pause.lowerBound - metadata.hostTimeOrigin) + (beforeStop - pause.upperBound)
        let video = try await Self.videoRange(of: raw.screenURL)
        let videoDuration = video.end - video.start
        #expect(abs(videoDuration - expected) <= 0.1, "video \(videoDuration) vs host-clock \(expected)")
        #expect(abs(raw.duration - videoDuration) <= 0.02)
        let tracks = try await Self.audioTracks(of: raw.screenURL)
        #expect(tracks.count == 2)
        for (index, track) in tracks.enumerated() {
            RecordingSpikeTests.log("pause audio track \(index): \(track.summary), video \(videoDuration), expected \(expected)")
            #expect(abs(track.duration - videoDuration) <= 0.05, "track \(index) \(track.duration) vs video \(videoDuration)")
        }
    }

    // MARK: Level meter math

    @Test func levelMath() {
        #expect(AudioLevelMath.dBFS(1) == 0)
        #expect(abs(AudioLevelMath.dBFS(0.5) - -6.0206) < 0.001)
        #expect(AudioLevelMath.dBFS(0) == AudioLevelMath.floorDBFS)
        #expect(abs(AudioLevelMath.linear(dBFS: -20) - 0.1) < 1e-6)

        // Sine of amplitude 0.5: RMS 0.5/√2 (−9.03 dBFS), peak 0.5.
        let sine = (0..<48_000).map { Float(0.5 * sin(2 * Double.pi * 1_000 * Double($0) / 48_000)) }
        let reading = AudioLevelMath.reading(of: sine)
        #expect(abs(reading.rms - 0.5 / 2.0.squareRoot().float) < 0.001)
        #expect(abs(reading.peak - 0.5) < 0.001)
        #expect(abs(reading.rmsDBFS - -9.03) < 0.02)
        #expect(abs(reading.duration - 1) < 1e-9)
        let silence = AudioLevelMath.reading(of: [Float](repeating: 0, count: 480))
        #expect(silence.rms == 0 && silence.peak == 0)
        #expect(silence.peakDBFS == AudioLevelMath.floorDBFS)

        #expect(AudioLevelMath.meterPosition(dBFS: -70) == 0)
        #expect(AudioLevelMath.meterPosition(dBFS: -30) == 0.5)
        #expect(AudioLevelMath.meterPosition(dBFS: 3) == 1)

        // Peak hold: 24 dB/s release → −12 dB after 0.5 s; a louder buffer wins.
        let held = AudioLevelMath.heldPeak(previous: 1, current: 0, elapsed: 0.5)
        #expect(abs(AudioLevelMath.dBFS(held) - -12) < 0.01)
        #expect(AudioLevelMath.heldPeak(previous: 0.1, current: 0.8, elapsed: 0.02) == 0.8)
    }

    /// Reads float32 sample buffers the way SCStream delivers them.
    @Test func levelOfSampleBuffer() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try #require(SyntheticFrameSource.makeToneBuffer(
            format: format, frequency: 440, startFrame: 0, frameCount: 4_800, pts: .zero
        ))
        let reading = try #require(AudioLevelMath.reading(of: buffer))
        #expect(reading.frameCount == 4_800)
        #expect(reading.sampleRate == 48_000)
        #expect(abs(reading.duration - 0.1) < 1e-9)
        #expect(abs(reading.peak - 0.25) < 0.001)
        #expect(abs(reading.rms - 0.25 / 2.0.squareRoot().float) < 0.002)

        let meter = AudioLevelMeter()
        meter.process(buffer, kind: .system)
        #expect(abs(meter.level(.system) - 0.25) < 0.001)
        #expect(meter.level(.microphone) == 0)
        #expect(meter.lastReading(.system) == reading)
    }

    /// Silent mic: ≥ 3 s at or below −60 dBFS raises the flag; a louder
    /// buffer drops it.
    @Test func silentMicrophoneDetection() {
        var detector = SilenceDetector()
        for _ in 0..<29 { detector.add(peakDBFS: -70, duration: 0.1) }
        #expect(!detector.isSilent)
        let silentAtThreshold = detector.add(peakDBFS: -60, duration: 0.1) // exactly −60 counts, 3.0 s
        #expect(silentAtThreshold)
        let silentAfterLouder = detector.add(peakDBFS: -59, duration: 0.02)
        #expect(!silentAfterLouder)
        #expect(detector.silentDuration == 0)

        let meter = AudioLevelMeter()
        let quiet = AudioLevelReading(rms: 0.0001, peak: 0.0005, frameCount: 4_800, sampleRate: 48_000) // −66 dBFS peak
        for _ in 0..<29 { meter.record(quiet, kind: .microphone) }
        #expect(!meter.isSilent(.microphone))
        meter.record(quiet, kind: .microphone)
        #expect(meter.isSilent(.microphone))
        #expect(!meter.isSilent(.system))
        meter.record(AudioLevelReading(rms: 0.05, peak: 0.1, frameCount: 480, sampleRate: 48_000), kind: .microphone)
        #expect(!meter.isSilent(.microphone))
    }

    // MARK: Writer helpers

    /// A buffer straddling T0 is cut to start at T0.
    @Test func trimAudioAtSessionStart() throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let pts = CMTime(seconds: 100, preferredTimescale: 1_000_000_000)
        let buffer = try #require(SyntheticFrameSource.makeToneBuffer(format: format, frequency: 440, startFrame: 0, frameCount: 1_024, pts: pts))
        let start = pts + CMTime(value: 10, timescale: 1_000) // 480 frames in
        let trimmed = try #require(RecordingWriter.trimmedAudio(buffer, from: start))
        #expect(CMSampleBufferGetNumSamples(trimmed) == 1_024 - 480)
        #expect(abs((trimmed.presentationTimeStamp - start).seconds) < 1e-6)
        #expect(RecordingWriter.trimmedAudio(buffer, from: pts + CMTime(value: 1, timescale: 1)) == nil)
        #expect(RecordingWriter.trimmedAudio(buffer, from: pts - CMTime(value: 1, timescale: 1)) === buffer)
    }

    /// A still screen sends few frames (VFR). With or without audio, the
    /// video track must last until the stop instant, and the audio tracks
    /// must not run past it.
    @Test(arguments: [false, true])
    func stillScreenVideoLastsUntilStop(withAudio: Bool) async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "still.mov")
        let writer = try RecordingWriter(configuration: RecordingWriterConfiguration(
            outputURL: url, pixelWidth: 320, pixelHeight: 180, codec: .h264, bitrate: 2_000_000, fps: 30,
            audioTracks: withAudio ? [.system] : []
        ))
        let t0 = CMTime(seconds: 1_000, preferredTimescale: 1_000_000_000)
        for index in 0..<2 {
            let frame = try Self.videoFrame(pts: t0 + CMTime(value: CMTimeValue(index), timescale: 30))
            #expect(writer.appendVideo(frame))
        }
        if withAudio {
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
            for index in 0..<48 { // 48 × 1024 frames ≈ 1.02 s
                let pts = t0 + CMTime(value: CMTimeValue(index * 1_024), timescale: 48_000)
                let buffer = try #require(SyntheticFrameSource.makeToneBuffer(
                    format: format, frequency: 440, startFrame: Int64(index * 1_024), frameCount: 1_024, pts: pts
                ))
                while !writer.appendAudio(buffer, kind: .system) { try await Task.sleep(for: .milliseconds(5)) }
            }
        }
        let summary = try await writer.finish(at: t0 + CMTime(value: 1, timescale: 1))
        #expect(abs(summary.duration - 1) < 0.001)
        #expect(summary.audioTracks == (withAudio ? [.system] : []))
        let video = try await Self.videoRange(of: url)
        let movie = try await AVURLAsset(url: url).load(.duration).seconds
        RecordingSpikeTests.log("still screen (audio \(withAudio)): video \(video.start)…\(video.end), movie \(movie)")
        #expect(abs(video.end - 1) < 0.02, "video ends at \(video.end)")
        #expect(abs(movie - 1) < 0.02, "movie \(movie)")
        if withAudio {
            let track = try #require(try await Self.audioTracks(of: url).first)
            #expect(track.start + track.duration <= 1.001, "audio \(track.summary)")
        }
    }

    static func videoFrame(pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer)
        let image = try #require(pixelBuffer)
        SyntheticFrameSource.draw(frame: 0, into: image)
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &description)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: try #require(description),
            sampleTiming: &timing, sampleBufferOut: &sampleBuffer
        )
        return try #require(sampleBuffer)
    }

    @Test func writerAudioSettings() {
        let config = RecordingWriterConfiguration(
            outputURL: URL(fileURLWithPath: "/tmp/x.mov"), pixelWidth: 640, pixelHeight: 360, codec: .h264,
            bitrate: 2_000_000, fps: 30, audioTracks: [.system, .microphone]
        )
        #expect(config.audioTracks == [.microphone, .system])
        let settings = config.audioOutputSettings
        #expect(settings[AVSampleRateKey] as? Int == 48_000)
        #expect(settings[AVNumberOfChannelsKey] as? Int == 2)
        #expect(settings[AVEncoderBitRateKey] as? Int == 192_000)
        #expect(settings[AVFormatIDKey] as? AudioFormatID == kAudioFormatMPEG4AAC)
    }

    // MARK: Devices, debug parameters

    @Test func microphoneChoiceResolution() {
        let list = MicrophoneDeviceList(
            devices: [
                MicrophoneDevice(id: "builtin", name: "MacBook Pro Microphone", isExternal: false),
                MicrophoneDevice(id: "usb", name: "USB Mic", isExternal: true),
            ],
            defaultDeviceID: "builtin"
        )
        #expect(list.resolve(.systemDefault)?.id == "builtin")
        #expect(list.resolve(.device(uniqueID: "usb"))?.id == "usb")
        #expect(list.resolve(.device(uniqueID: "gone"))?.id == "builtin")
        #expect(list.captureDeviceID(for: .systemDefault) == nil)
        #expect(list.captureDeviceID(for: .device(uniqueID: "usb")) == "usb")
        #expect(list.captureDeviceID(for: .device(uniqueID: "gone")) == nil)
        #expect(MicrophoneDeviceList.empty.resolve(.systemDefault) == nil)
    }

    @Test func audioDevicesJSON() throws {
        let list = MicrophoneDeviceList(devices: [MicrophoneDevice(id: "a", name: "A", isExternal: true)], defaultDeviceID: "a")
        let data = try RecordingAudioDebug.audioDevicesJSON(list, authorization: .notDetermined)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["defaultDeviceID"] as? String == "a")
        #expect((object["devices"] as? [[String: Any]])?.first?["name"] as? String == "A")
        #expect(object["microphoneAuthorization"] as? String == "notDetermined")
        // The live list only enumerates devices (no prompt).
        _ = try RecordingAudioDebug.audioDevicesJSON()
    }

    @Test func debugRecordAudioParameters() {
        func items(_ query: String) -> [URLQueryItem] {
            URLComponents(string: "hakoshot://debug-record?\(query)")?.queryItems ?? []
        }
        let both = RecordingDebug.Parameters(queryItems: items("source=synthetic&systemAudio=1&mic=1"))
        #expect(both.systemAudio)
        #expect(both.microphone == .systemDefault)
        let device = RecordingDebug.Parameters(queryItems: items("mic=BuiltInMicrophoneDevice"))
        #expect(device.microphone == .device(uniqueID: "BuiltInMicrophoneDevice"))
        #expect(!device.systemAudio)
        let off = RecordingDebug.Parameters(queryItems: items("mic=0&systemaudio=false"))
        #expect(off.microphone == nil && !off.systemAudio)
    }

    // MARK: Real system audio (skipped when locked / no permission)

    /// Plays Glass.aiff in a loop during a 3 s real recording; the system
    /// track must be well above silence. The video shows the user's screen:
    /// only numbers are checked, then the session is deleted.
    @Test(.enabled(if: ScreenAvailability.isUsable, "Screen is locked or the test host has no Screen Recording permission"),
          .timeLimit(.minutes(1)))
    func realSystemAudioIsCaptured() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/bin/sh")
        player.arguments = ["-c", "while true; do /usr/bin/afplay /System/Library/Sounds/Glass.aiff; done"]
        try player.run()
        defer {
            player.terminate()
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"), arguments: ["-f", "afplay /System/Library/Sounds/Glass.aiff"])
        }

        let engine = RecordingEngine(sessionsRoot: root)
        let layout = DisplayLayoutProvider.currentLayout()
        let main = try #require(layout.mainDisplay)
        var options = RecordingOptions.default
        options.capturesSystemAudio = true
        let request = RecordingRequest(
            target: .area(GlobalRect(x: 100, y: 100, width: 320, height: 180), displayID: main.id),
            options: options, source: .screen
        )
        _ = try await engine.start(request)
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(3))
        let level = await engine.stats.systemAudioLevel
        let raw = try await engine.stop()

        #expect(raw.audioTracks == [.system])
        let tracks = try await Self.audioTracks(of: raw.screenURL)
        let track = try #require(tracks.first)
        // A still screen gives few video frames (VFR), so compare with the
        // movie duration (the session end = stop instant).
        let movie = try await AVURLAsset(url: raw.screenURL).load(.duration).seconds
        let rms = try await Self.rmsDBFS(url: raw.screenURL, trackIndex: 0)
        RecordingSpikeTests.log("real system audio: \(track.summary), movie \(movie), raw \(raw.duration), rms \(rms) dBFS, live level \(String(describing: level))")
        #expect(rms > -60, "system audio rms \(rms) dBFS")
        #expect(abs(track.duration - movie) <= 0.05, "audio \(track.duration) vs movie \(movie)")
        #expect(abs(track.start) <= 0.05, "audio starts at \(track.start)")
    }

    // MARK: Helpers

    struct AudioTrackInfo {
        var codec: String
        var sampleRate: Double
        var channels: Int
        var start: Double
        var duration: Double
        var summary: String { "\(codec) \(Int(sampleRate)) Hz \(channels) ch, \(String(format: "%.3f", start))+\(String(format: "%.3f", duration)) s" }
    }

    static func audioTracks(of url: URL) async throws -> [AudioTrackInfo] {
        let asset = AVURLAsset(url: url)
        var result: [AudioTrackInfo] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let descriptions = try await track.load(.formatDescriptions)
            let description = try #require(descriptions.first)
            let subtype = CMFormatDescriptionGetMediaSubType(description)
            let codec = String(decoding: withUnsafeBytes(of: subtype.bigEndian) { Array($0) }, as: UTF8.self)
            let asbd = try #require(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee)
            let range = try await track.load(.timeRange)
            result.append(AudioTrackInfo(
                codec: codec, sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame),
                start: range.start.seconds, duration: range.duration.seconds
            ))
        }
        return result
    }

    static func videoRange(of url: URL) async throws -> (start: Double, end: Double) {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let range = try await track.load(.timeRange)
        return (range.start.seconds, range.end.seconds)
    }

    /// Decoded channel 0 of a stereo audio track as float samples.
    static func samples(url: URL, trackIndex: Int) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let loaded = try await asset.loadTracks(withMediaType: .audio)
        let track = try #require(loaded.indices.contains(trackIndex) ? loaded[trackIndex] : nil)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        #expect(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = buffer.dataBuffer else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / 4)
            chunk.withUnsafeMutableBytes { bytes in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes.baseAddress!)
            }
            samples.append(contentsOf: chunk)
        }
        // Interleaved stereo → channel 0.
        return stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }

    /// Frequency from zero crossings over the middle of the track (skips the
    /// AAC priming / fade at both ends).
    static func dominantFrequency(url: URL, trackIndex: Int) async throws -> Double {
        let samples = try await samples(url: url, trackIndex: trackIndex)
        let sampleRate = 48_000.0
        let lower = samples.count / 4
        let upper = samples.count * 3 / 4
        try #require(upper - lower > 4_800, "too few samples: \(samples.count)")
        var crossings = 0
        for i in (lower + 1)..<upper where (samples[i - 1] < 0) != (samples[i] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(upper - lower) / sampleRate)
    }

    static func rmsDBFS(url: URL, trackIndex: Int) async throws -> Float {
        let samples = try await samples(url: url, trackIndex: trackIndex)
        return AudioLevelMath.reading(of: samples).rmsDBFS
    }
}

private extension Double {
    var float: Float { Float(self) }
}
