import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Pause / resume / restart / discard (plan §4.6, §7 R1.3) on the synthetic
/// source. Recordings go to a throwaway sessions root.
@Suite("Recording pause", .serialized)
struct RecordingPauseTests {
    static func syntheticRequest() -> RecordingRequest {
        RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 640, height: 360), displayID: CGMainDisplayID()),
            source: .synthetic
        )
    }

    // MARK: Engine

    /// 3 s record + 2 s pause + 3 s record → 6.0 ± 0.1 s; the pause is in events.json.
    ///
    /// On a loaded machine sleeps overshoot and `waitForFirstFrame()` can
    /// return late (media time 0 is the first frame, not the wait's return),
    /// so the file is checked against host-clock times: origin (T0) → pause
    /// start, resume → stop. In isolation this is 6.0 ± 0.1 s.
    @Test(.timeLimit(.minutes(1)))
    func pauseIsLeftOutOfTheFile() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        _ = try await engine.start(Self.syntheticRequest())
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(3))

        try await engine.pause()
        try await engine.pause() // idempotent
        #expect(await engine.isPaused)
        let atPause = await engine.stats
        #expect(atPause.isPaused)
        #expect(await engine.timeline?.isPaused == true)
        try await Task.sleep(for: .seconds(2))
        let endOfPause = await engine.stats
        // Frozen while paused: no frames, no duration.
        #expect(abs(endOfPause.duration - atPause.duration) < 0.05, "\(atPause.duration) → \(endOfPause.duration)")
        #expect(endOfPause.framesWritten <= atPause.framesWritten + 1)

        try await engine.resume()
        #expect(await !engine.isPaused)
        try await Task.sleep(for: .seconds(3))
        let beforeStop = RecordingEngine.hostNow().seconds
        let raw = try await engine.stop()

        let info = try await RecordingEngineTests.inspect(raw.screenURL)
        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: try #require(raw.eventsURL)))
        #expect(metadata.pauses.count == 1)
        let pause = try #require(metadata.pauses.first)
        let first = pause.lowerBound - metadata.hostTimeOrigin
        // Stop happens inside engine.stop(), a little after `beforeStop`.
        let expected = first + (beforeStop - pause.upperBound)
        RecordingSpikeTests.log("pause 3+2+3: raw \(raw.duration), file \(info.duration), expected \(expected), first \(first), pause \(pause.upperBound - pause.lowerBound), frames \(info.frameCount)")
        #expect(abs(info.duration - expected) <= 0.1, "file \(info.duration) vs host-clock \(expected)")
        #expect(abs(raw.duration - info.duration) <= 0.02)
        #expect(first >= 2.95, "first segment \(first)")

        let pauseLength = pause.upperBound - pause.lowerBound
        #expect(pauseLength >= 1.95 && pauseLength <= 2.5, "pause \(pauseLength)")
        // The paused 2 s are not in the file: host span T0 → stop minus the pause.
        #expect(abs((beforeStop - metadata.hostTimeOrigin - pauseLength) - expected) <= 0.001)
        // The timeline agrees with the file.
        let timeline = metadata.timeline
        #expect(timeline.mediaTime(host: pause.lowerBound + 1) == nil)
        let resumeMedia = try #require(timeline.mediaTime(host: pause.upperBound))
        #expect(abs(resumeMedia - first) <= 0.001)
    }

    /// Stop while paused: the file ends at the pause start; the open pause is
    /// written closed at the stop time.
    @Test(.timeLimit(.minutes(1)))
    func stopWhilePaused() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        _ = try await engine.start(Self.syntheticRequest())
        #expect(await engine.waitForFirstFrame())
        let clock = ContinuousClock()
        let recordStart = clock.now
        try await Task.sleep(for: .seconds(1))
        let recorded = (clock.now - recordStart) / .seconds(1)
        try await engine.pause()
        try await Task.sleep(for: .seconds(1))
        let raw = try await engine.stop()
        let info = try await RecordingEngineTests.inspect(raw.screenURL)
        #expect(abs(raw.duration - recorded) <= 0.1, "raw \(raw.duration) vs measured \(recorded)")
        #expect(abs(info.duration - recorded) <= 0.1, "file \(info.duration) vs measured \(recorded)")
        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: try #require(raw.eventsURL)))
        #expect(metadata.pauses.count == 1)
        #expect(abs((metadata.pauses.first.map { $0.upperBound - $0.lowerBound } ?? 0) - 1.0) <= 0.1)
    }

    /// Restart → only the segment after it (also from paused).
    @Test(.timeLimit(.minutes(1)))
    func restartKeepsOnlyTheLastSegment() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        let handle = try await engine.start(Self.syntheticRequest())
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(2))
        try await engine.pause()
        try await Task.sleep(for: .milliseconds(500))

        try await engine.restart()
        #expect(await !engine.isPaused)
        #expect(await engine.currentHandle?.sessionFolder == handle.sessionFolder)
        #expect(await engine.waitForFirstFrame())
        let clock = ContinuousClock()
        let segmentStart = clock.now
        try await Task.sleep(for: .seconds(1.5))
        let segment = (clock.now - segmentStart) / .seconds(1)
        let raw = try await engine.stop()

        let info = try await RecordingEngineTests.inspect(raw.screenURL)
        RecordingSpikeTests.log("restart: raw \(raw.duration), file \(info.duration), measured last segment \(segment)")
        #expect(raw.sessionFolder == handle.sessionFolder)
        // Only the last segment (the 2 s before the restart are gone).
        #expect(abs(raw.duration - segment) <= 0.1, "raw \(raw.duration) vs measured \(segment)")
        #expect(abs(info.duration - segment) <= 0.1, "file \(info.duration) vs measured \(segment)")
        let metadata = try RecordingMetadata(jsonData: Data(contentsOf: try #require(raw.eventsURL)))
        #expect(metadata.pauses.isEmpty)
        // Only screen.mov + events.json (+ the recovery marker) in the folder.
        let files = try FileManager.default.contentsOfDirectory(atPath: raw.sessionFolder.path).sorted()
        #expect(files == ["events.json", "screen.mov", "session.json"])
    }

    /// Discard (while paused) → the session folder is gone.
    @Test(.timeLimit(.minutes(1)))
    func discardWhilePausedRemovesFolder() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        let handle = try await engine.start(Self.syntheticRequest())
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .milliseconds(500))
        try await engine.pause()
        #expect(FileManager.default.fileExists(atPath: handle.sessionFolder.path))
        await engine.discard()
        #expect(!FileManager.default.fileExists(atPath: handle.sessionFolder.path))
        #expect(await !engine.isRecording)
        await #expect(throws: RecordingError.noActiveSession) { try await engine.pause() }
        await #expect(throws: RecordingError.noActiveSession) { try await engine.resume() }
        await #expect(throws: RecordingError.noActiveSession) { try await engine.restart() }
    }

    // MARK: RecordingSession

    @Test(.timeLimit(.minutes(1)))
    func sessionFlowPauseResumeStop() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(engine: RecordingEngine(sessionsRoot: root), tickInterval: .milliseconds(50))
        var transitions: [RecordingSessionState.Kind] = []
        session.onStateChange = { _, new in transitions.append(new.kind) }

        #expect(await !session.togglePause()) // idle: ignored
        #expect(session.prepare())
        #expect(session.beginCountdown())
        _ = try await session.start(Self.syntheticRequest())
        #expect(session.state == .recording)
        try await Task.sleep(for: .seconds(1))
        #expect(session.elapsed > 0.7, "elapsed \(session.elapsed)") // ticker ran

        #expect(await session.togglePause())
        #expect(session.state == .paused)
        #expect(session.stats.isPaused)
        let frozen = session.elapsed
        try await Task.sleep(for: .seconds(1))
        await session.refresh()
        #expect(abs(session.elapsed - frozen) < 0.05)
        #expect(await !session.pause()) // already paused

        #if DEBUG
        let snapshot = await session.debugSnapshot()
        #expect(snapshot.state == "paused")
        #expect(snapshot.isPaused)
        #expect(snapshot.pauses.count == 1) // open pause: [start]
        #endif

        #expect(await session.togglePause())
        #expect(session.state == .recording)
        try await Task.sleep(for: .seconds(1))
        let raw = try await session.stop()
        // Two ~1 s segments; sleeps may overshoot a little under load.
        #expect(session.state == .finished)
        #expect(session.result == raw)
        #expect(raw.duration > 1.9 && raw.duration < 2.4, "raw \(raw.duration)")
        #expect(session.elapsed == raw.duration)
        #expect(transitions == [.preparing, .countdown, .recording, .paused, .recording, .finalizing, .finished])

        // Nothing to pause / restart / stop after the result.
        #expect(await !session.pause())
        await #expect(throws: RecordingError.self) { try await session.restart() }
        await #expect(throws: RecordingError.self) { _ = try await session.stop() }
        session.reset()
        #expect(session.state == .idle)
        #expect(session.result == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionRestartAndDiscard() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(engine: RecordingEngine(sessionsRoot: root))
        let handle = try await session.start(Self.syntheticRequest()) // idle → preparing → recording
        #expect(session.state == .recording)
        try await Task.sleep(for: .seconds(1))
        await session.pause()
        try await session.restart()
        #expect(session.state == .recording)
        #expect(session.elapsed < 0.3, "elapsed after restart \(session.elapsed)")

        #expect(await session.discard())
        #expect(session.state == .discarded)
        #expect(!FileManager.default.fileExists(atPath: handle.sessionFolder.path))
        #expect(await !session.discard())

        // A new recording after a discard starts from a clean state.
        _ = try await session.start(Self.syntheticRequest())
        #expect(session.state == .recording)
        #expect(await session.discard())
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func sessionDiscardDuringCountdown() async throws {
        let root = try RecordingEngineTests.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let session = RecordingSession(engine: RecordingEngine(sessionsRoot: root))
        session.prepare()
        session.beginCountdown()
        #expect(await session.discard())
        #expect(session.state == .discarded)
        await #expect(throws: RecordingError.self) { _ = try await session.stop() }
    }

    // MARK: SampleRetimer

    @Test func retimerDropsSamplesInsidePauses() {
        func t(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1_000_000) }
        var retimer = SampleRetimer()
        let start = t(100)
        #expect(retimer.outputTime(forHostTime: t(101)) == t(101))
        retimer.pause(at: t(103))
        #expect(retimer.isPaused)
        #expect(retimer.outputTime(forHostTime: t(102.9)) == t(102.9)) // captured before the pause
        #expect(retimer.outputTime(forHostTime: t(103)) == nil)
        #expect(retimer.outputTime(forHostTime: t(104)) == nil)
        // Audio buffer straddling the pause start: dropped whole.
        #expect(retimer.outputTime(forHostTime: t(102.99), duration: t(0.02)) == nil)
        #expect(retimer.outputTime(forStopTime: t(104)) == t(103))

        let counted = retimer.resume(at: t(105), sessionStart: start)
        #expect(counted == t(2))
        #expect(retimer.pauseOffset == t(2))
        #expect(retimer.pauses == [103...105])
        #expect(retimer.outputTime(forHostTime: t(104.9)) == nil) // late delivery from the pause
        #expect(retimer.outputTime(forHostTime: t(106)) == t(104))
        #expect(retimer.outputTime(forStopTime: t(108)) == t(106))

        // A pause before the first frame adds no offset.
        var early = SampleRetimer()
        early.pause(at: t(10))
        #expect(early.resume(at: t(12), sessionStart: nil) == .zero)
        #expect(early.pauseOffset == .zero)
        #expect(early.pauses.isEmpty)
        #expect(early.outputTime(forHostTime: t(11)) == nil)
        #expect(early.outputTime(forHostTime: t(12.5)) == t(12.5))

        // Open pause closed at the stop time for metadata.
        var open = SampleRetimer()
        open.pause(at: t(50))
        #expect(open.pauses(closingOpenPauseAt: t(51), sessionStart: t(40)) == [50...51])
        #expect(open.pauses(closingOpenPauseAt: t(51), sessionStart: nil).isEmpty)
    }

    @Test func retimerShiftsBufferTiming() throws {
        let buffer = try Self.makeVideoSample(pts: CMTime(value: 5_000, timescale: 1_000))
        let shifted = try #require(SampleRetimer.retimed(buffer, by: CMTime(value: 2_000, timescale: 1_000)))
        #expect(shifted.presentationTimeStamp == CMTime(value: 3_000, timescale: 1_000))
        #expect(shifted.duration == buffer.duration)
        #expect(shifted.imageBuffer === buffer.imageBuffer)
        // Zero offset returns the same buffer.
        #expect(SampleRetimer.retimed(buffer, by: .zero) === buffer)

        let restamped = try #require(SampleRetimer.restamped(buffer, at: CMTime(value: 9, timescale: 1)))
        #expect(restamped.presentationTimeStamp == CMTime(value: 9, timescale: 1))
        #expect(!restamped.decodeTimeStamp.isValid)
    }

    static func makeVideoSample(pts: CMTime) throws -> CMSampleBuffer {
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
        let image = try #require(pixelBuffer)
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: try #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        return try #require(sample)
    }
}
