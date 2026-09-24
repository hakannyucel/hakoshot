import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Engine integration tests (plan §7 R0.2, §8.2). Recordings go to a
/// throwaway sessions root that is removed afterwards.
@Suite("Recording engine", .serialized)
struct RecordingEngineTests {
    // MARK: Synthetic source (no screen, no permission)

    /// Durations are checked against the host clock (T0 from events.json →
    /// just before stop): under load `waitForFirstFrame()` can return late
    /// and sleeps overshoot, so "3 s" is not what was recorded (R1.3 note).
    @Test(.timeLimit(.minutes(1)))
    func syntheticThreeSecondsH264() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        let request = RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 640, height: 360), displayID: CGMainDisplayID()),
            source: .synthetic
        )
        _ = try await engine.start(request)
        try #require(await engine.waitForFirstFrame(), "no frame within 5 s")
        try await Task.sleep(for: .seconds(3))
        let beforeStop = RecordingEngine.hostNow().seconds
        let raw = try await engine.stop()
        let eventsURL = try #require(raw.eventsURL)
        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: eventsURL))
        // Stop happens inside engine.stop(), a little after `beforeStop`.
        let measured = beforeStop - metadata.hostTimeOrigin

        let expected = RecordingGeometry.plan(pointSize: CGSize(width: 640, height: 360), backingScale: Double(raw.scale))
        #expect(raw.pixelSize == expected.pixelSize)
        #expect(raw.pointSize == CGSize(width: 640, height: 360))
        #expect(raw.fps == 60)
        #expect(measured >= 2.95, "measured \(measured)")
        #expect(abs(raw.duration - measured) <= 0.1, "raw \(raw.duration) vs host-clock \(measured)")
        #expect(raw.screenURL.lastPathComponent == "screen.mov")
        #expect(raw.screenURL.deletingLastPathComponent() == raw.sessionFolder)

        let info = try await Self.inspect(raw.screenURL)
        RecordingSpikeTests.log("synthetic3s: \(info), raw.duration \(raw.duration), host-clock \(measured)")
        #expect(abs(info.duration - measured) <= 0.1, "duration \(info.duration) vs host-clock \(measured)")
        #expect(info.videoTracks == 1)
        #expect(info.audioTracks == 0)
        #expect(info.size == expected.pixelSize)
        #expect(info.codec == "avc1")
        #expect(info.frameCount >= 150, "frames \(info.frameCount)")

        #expect(metadata.geometry.pixelWidth == Int(expected.pixelWidth))
        #expect(metadata.hostTimeOrigin > 0)
        #expect(metadata.cursorBakedIn)
    }

    @Test(.timeLimit(.minutes(1)))
    func syntheticHEVC() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        var options = RecordingOptions.default
        options.codec = .hevc
        options.fps = 30
        options.scaleTo1x = true
        let request = RecordingRequest(
            target: .area(GlobalRect(x: 10, y: 10, width: 500, height: 300), displayID: CGMainDisplayID()),
            options: options, source: .synthetic
        )
        let (raw, measured) = try await Self.recordMeasured(engine, request, seconds: 1)
        let info = try await Self.inspect(raw.screenURL)
        #expect(info.codec == "hvc1")
        #expect(info.size == CGSize(width: 500, height: 300))
        #expect(abs(info.duration - measured) <= 0.1, "file \(info.duration) vs host-clock \(measured)")
    }

    /// H.264 over the hardware limit (5K) switches to HEVC (spike 1: the
    /// hardware H.264 encoder refuses 5120×2880).
    @Test(.timeLimit(.minutes(1)))
    func synthetic5KSwitchesToHEVC() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        // Fallback geometry (scale 2) when no display matches the ID.
        let request = RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 2560, height: 1440), displayID: 0xFFFF_FFF0),
            source: .synthetic
        )
        let (raw, measured) = try await Self.recordMeasured(engine, request, seconds: 1)
        #expect(raw.pixelSize == CGSize(width: 5120, height: 2880))
        let info = try await Self.inspect(raw.screenURL)
        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: try #require(raw.eventsURL)))
        RecordingSpikeTests.log("synthetic5K: \(info), dropped \(metadata.droppedFrames)")
        #expect(info.codec == "hvc1")
        #expect(info.size == CGSize(width: 5120, height: 2880))
        #expect(abs(info.duration - measured) <= 0.1, "file \(info.duration) vs host-clock \(measured)")
    }

    @Test(.timeLimit(.minutes(1)))
    func discardRemovesSessionFolder() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        let request = RecordingRequest(target: .display(CGMainDisplayID()), source: .synthetic)
        let handle = try await engine.start(request)
        #expect(await engine.waitForFirstFrame())
        await #expect(throws: RecordingError.alreadyRecording) { try await engine.start(request) }
        try await Task.sleep(for: .milliseconds(300))
        let stats = await engine.stats
        #expect(stats.framesWritten > 0)
        #expect(stats.duration > 0.1)
        #expect(FileManager.default.fileExists(atPath: handle.sessionFolder.path))
        await engine.discard()
        #expect(!FileManager.default.fileExists(atPath: handle.sessionFolder.path))
        #expect(await engine.stats == .zero)
        await #expect(throws: RecordingError.noActiveSession) { try await engine.stop() }
    }

    @Test func resolvesAreaOnDisplay() throws {
        let layout = DisplayLayout(
            displays: [
                DisplayDescriptor(id: 1, appKitFrame: CGRect(x: 0, y: 0, width: 2560, height: 1440), backingScaleFactor: 2),
                DisplayDescriptor(id: 2, appKitFrame: CGRect(x: 2560, y: 0, width: 1710, height: 1112), backingScaleFactor: 2),
            ],
            mainDisplayID: 1
        )
        let area = try RecordingEngine.resolve(
            .area(GlobalRect(x: 2600, y: 400, width: 300, height: 200), displayID: 2), layout: layout, windowBounds: { _ in nil }
        )
        #expect(area.displayID == 2)
        // Display 2's top in Quartz space: 1440 − 1112 = 328.
        #expect(area.sourceRect == CGRect(x: 40, y: 72, width: 300, height: 200))
        let display = try RecordingEngine.resolve(.display(1), layout: layout, windowBounds: { _ in nil })
        #expect(display.sourceRect == nil)
        #expect(display.pointSize == CGSize(width: 2560, height: 1440))
        let window = try RecordingEngine.resolve(
            .window(7), layout: layout, windowBounds: { _ in GlobalRect(x: 2400, y: 100, width: 400, height: 300) }
        )
        #expect(window.displayID == 1)
        #expect(window.sourceRect == CGRect(x: 2400, y: 100, width: 160, height: 300))
        #expect(throws: RecordingError.displayNotFound(9)) {
            try RecordingEngine.resolve(.display(9), layout: layout, windowBounds: { _ in nil })
        }
        #expect(throws: RecordingError.invalidTarget) {
            try RecordingEngine.resolve(
                .area(GlobalRect(x: 5000, y: 0, width: 10, height: 10), displayID: 1), layout: layout, windowBounds: { _ in nil }
            )
        }
    }

    @Test func writerSettingsFollowQuality() {
        let plan = RecordingGeometry.plan(pointSize: CGSize(width: 960, height: 540), backingScale: 2)
        let config = RecordingWriterConfiguration(outputURL: URL(fileURLWithPath: "/tmp/x.mov"), plan: plan, quality: .high, fps: 60)
        #expect(config.bitrate == 6_220_800)
        #expect(config.codec == .h264)
        let studio = RecordingEngine.effectiveQuality(RecordingRequest(target: .display(1), profile: .studio))
        #expect(studio == .ultra)
    }

    @Test(.timeLimit(.minutes(1)))
    func debugRecordMovesFileToOut() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appending(path: "out/debug.mov")
        let url = try await RecordingDebug.record(
            rect: CGRect(x: 0, y: 0, width: 320, height: 180), seconds: 1, source: .synthetic, out: out,
            engine: RecordingEngine(sessionsRoot: root)
        )
        #expect(url == out)
        let info = try await Self.inspect(out)
        #expect(abs(info.duration - 1.0) <= 0.1)
        // Only the `out` folder is left; the session folder was removed.
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["out"])
    }

    @Test func debugRecordParameters() {
        let items = "x=10&y=20&width=640&height=360&seconds=2.5&source=synthetic&out=/tmp/a.mov&fps=30&codec=hevc&cursor=false"
            .split(separator: "&").map { pair -> URLQueryItem in
                let parts = pair.split(separator: "=", maxSplits: 1)
                return URLQueryItem(name: String(parts[0]), value: String(parts[1]))
            }
        let parameters = RecordingDebug.Parameters(queryItems: items)
        #expect(parameters == RecordingDebug.Parameters(
            rect: CGRect(x: 10, y: 20, width: 640, height: 360), seconds: 2.5, source: .synthetic,
            out: URL(fileURLWithPath: "/tmp/a.mov"), fps: 30, codec: .hevc, showsCursor: false
        ))
        #expect(RecordingDebug.Parameters(queryItems: []) == RecordingDebug.Parameters())
    }

    // MARK: Real screen (skipped when locked / no permission)

    @Test(.enabled(if: ScreenAvailability.isUsable, "Screen is locked or the test host has no Screen Recording permission"),
          .timeLimit(.minutes(1)))
    func realScreen640x360() async throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        let layout = DisplayLayoutProvider.currentLayout()
        let main = try #require(layout.mainDisplay)
        let rect = GlobalRect(x: 100, y: 100, width: 640, height: 360)
        let request = RecordingRequest(target: .area(rect, displayID: main.id), source: .screen)
        let raw = try await Self.record(engine, request, seconds: 2)
        // The file shows the user's screen: only numbers are checked, then it's deleted.
        let expected = CGSize(width: 640 * main.backingScaleFactor, height: 360 * main.backingScaleFactor)
        let info = try await Self.inspect(raw.screenURL)
        RecordingSpikeTests.log("realScreen: \(info), raw.duration \(raw.duration)")
        #expect(raw.pixelSize == expected, "pixel size \(raw.pixelSize)")
        #expect(info.size == expected, "track size \(info.size)")
        #expect(info.videoTracks == 1)
        #expect(abs(info.duration - 2.0) <= 0.1, "duration \(info.duration)")
    }

    // MARK: Helpers

    static func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "HakoShotRecordingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Starts, waits for the first frame, records `seconds`, stops.
    static func record(_ engine: RecordingEngine, _ request: RecordingRequest, seconds: Double) async throws -> RawRecording {
        _ = try await engine.start(request)
        let started = await engine.waitForFirstFrame()
        try #require(started, "no frame within 5 s")
        try await Task.sleep(for: .seconds(seconds))
        return try await engine.stop()
    }

    /// Like `record`, plus the host-clock length T0 (events.json) → just
    /// before stop. Under load the wait and the sleep overshoot, so fixed
    /// durations are compared with this instead of `seconds` (R1.3 note).
    static func recordMeasured(_ engine: RecordingEngine, _ request: RecordingRequest, seconds: Double) async throws -> (RawRecording, Double) {
        _ = try await engine.start(request)
        try #require(await engine.waitForFirstFrame(), "no frame within 5 s")
        try await Task.sleep(for: .seconds(seconds))
        let beforeStop = RecordingEngine.hostNow().seconds
        let raw = try await engine.stop()
        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: try #require(raw.eventsURL)))
        return (raw, beforeStop - metadata.hostTimeOrigin)
    }

    struct MediaSummary {
        var duration: Double
        var videoTracks: Int
        var audioTracks: Int
        var size: CGSize
        var codec: String
        var frameCount: Int
    }

    static func inspect(_ url: URL) async throws -> MediaSummary {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let track = try #require(video.first)
        let size = try await track.load(.naturalSize)
        let descriptions = try await track.load(.formatDescriptions)
        let subtype = descriptions.first.map { CMFormatDescriptionGetMediaSubType($0) } ?? 0
        let codec = String(decoding: withUnsafeBytes(of: subtype.bigEndian) { Array($0) }, as: UTF8.self)
        let frames = try await track.load(.timeRange).duration.seconds * Double(try await track.load(.nominalFrameRate))
        return MediaSummary(
            duration: duration, videoTracks: video.count, audioTracks: audio.count,
            size: size, codec: codec, frameCount: Int(frames.rounded())
        )
    }
}

/// Whether a real screen recording can run in this test host.
enum ScreenAvailability {
    nonisolated static var isUsable: Bool {
        guard CGPreflightScreenCaptureAccess() else { return false }
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) != true
    }
}
