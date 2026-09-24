import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import KeyboardShortcuts
import Testing
@testable import HakoShot

/// R0.I: finalizer remux, output router decisions / file handling, and the
/// `record-screen` / `stop-recording` URLs (kayit-teknik-plan §7 R0.I, §8.2).
@Suite("Recording finalize + routing", .serialized)
struct RecordingFinalizeTests {
    // MARK: Finalizer

    @Test(.timeLimit(.minutes(1)))
    func remuxKeepsDurationAndTrackAsMP4() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "hako-finalize-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = RecordingEngine(sessionsRoot: root)
        var options = RecordingOptions.default
        options.fps = 30
        let request = RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 320, height: 180), displayID: CGMainDisplayID()),
            options: options,
            source: .synthetic
        )
        _ = try await engine.start(request)
        #expect(await engine.waitForFirstFrame())
        try await Task.sleep(for: .seconds(1.5))
        let raw = try await engine.stop()

        let result = try await RecordingFinalizer.finalize(raw)
        #expect(result.fileURL.pathExtension == "mp4")
        #expect(result.fileURL.deletingLastPathComponent().standardizedFileURL == raw.sessionFolder.standardizedFileURL)
        #expect(abs(result.duration - raw.duration) <= 0.05, "mp4 \(result.duration) vs raw \(raw.duration)")
        #expect(result.pixelSize == raw.pixelSize)
        #expect(result.targetKind == .area)
        #expect(result.format == .video)
        #expect(result.raw == raw)
        #expect(max(result.thumbnail.width, result.thumbnail.height) <= Int(RecordingThumbnailer.maxDimension))

        // MPEG-4 container: `ftyp` box with an mp4 brand, not QuickTime `qt  `.
        let head = try FileHandle(forReadingFrom: result.fileURL).read(upToCount: 12) ?? Data()
        #expect(String(decoding: head[4..<8], as: UTF8.self) == "ftyp")
        let brand = String(decoding: head[8..<12], as: UTF8.self)
        #expect(brand != "qt  ", "brand \(brand)")

        let asset = AVURLAsset(url: result.fileURL)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        #expect(video.count == 1)
        #expect(audio.isEmpty)
        let formats = try await video[0].load(.formatDescriptions)
        #expect(formats.first.map { CMFormatDescriptionGetMediaSubType($0) } == kCMVideoCodecType_H264)
    }

    @Test func posterTime() {
        #expect(abs(RecordingThumbnailer.posterTime(forDuration: 3) - 0.3) < 1e-9)
        #expect(RecordingThumbnailer.posterTime(forDuration: 60) == 0.5)
        #expect(RecordingThumbnailer.posterTime(forDuration: 0) == 0)
        #expect(RecordingThumbnailer.posterTime(forDuration: .nan) == 0)
    }

    // MARK: Router decisions

    @Test func decisionFollowsAfterRecordingSettings() {
        let config = AfterRecordingConfig(showQuickAccess: true, copyToClipboard: true, saveToDisk: false, openVideoEditor: true)
        let decision = RecordingOutputDecision.make(config: config, override: nil, copyAlsoSaves: true)
        #expect(decision == RecordingOutputDecision(save: false, copy: true, showQuickAccess: true, openVideoEditor: true))
        #expect(RecordingOutputDecision.make(config: .default, override: nil, copyAlsoSaves: false)
            == RecordingOutputDecision(showQuickAccess: true))
    }

    @Test func decisionOverrides() {
        let config = AfterRecordingConfig(showQuickAccess: true, copyToClipboard: true, saveToDisk: true, openVideoEditor: true)
        #expect(RecordingOutputDecision.make(config: config, override: .save, copyAlsoSaves: false)
            == RecordingOutputDecision(save: true))
        #expect(RecordingOutputDecision.make(config: config, override: .copy, copyAlsoSaves: false)
            == RecordingOutputDecision(copy: true))
        #expect(RecordingOutputDecision.make(config: config, override: .copy, copyAlsoSaves: true)
            == RecordingOutputDecision(save: true, copy: true))
        // Pin / annotate don't apply to videos: settings decide.
        #expect(RecordingOutputDecision.make(config: .default, override: .pin, copyAlsoSaves: false)
            == RecordingOutputDecision(showQuickAccess: true))
    }

    // MARK: Router file handling

    @MainActor
    @Test func saveOverrideSavesMP4KeepsHistoryCopyAndCleansSession() async throws {
        let fixture = try RouterFixture()
        defer { fixture.cleanup() }
        var historyCalls = 0
        var cardCalls = 0
        let historyCopy = fixture.dir.appending(path: "history/copy.mp4")
        let router = fixture.router(RecordingOutputDestinations(
            addToHistory: { result, savedURL in
                historyCalls += 1
                #expect(savedURL != nil)
                try? FileManager.default.createDirectory(at: historyCopy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: result.fileURL, to: historyCopy)
                return (UUID(), historyCopy)
            },
            showQuickAccess: { _, _ in cardCalls += 1; return UUID() }
        ))
        let outcome = await router.route(fixture.result, overriding: .save)

        let saved = try #require(outcome.savedURL)
        #expect(saved.pathExtension == "mp4")
        #expect(saved.deletingLastPathComponent().standardizedFileURL == fixture.exportFolder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(historyCalls == 1)
        #expect(cardCalls == 0)
        #expect(!outcome.copiedToClipboard)
        #expect(outcome.historyID != nil)
        #expect(outcome.fileURL == historyCopy)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFolder.path))
    }

    @MainActor
    @Test func defaultRouteShowsCardWithHistoryFile() async throws {
        let fixture = try RouterFixture()
        defer { fixture.cleanup() }
        let historyID = UUID()
        let historyCopy = fixture.dir.appending(path: "copy.mp4")
        var shown: RecordingResult?
        let router = fixture.router(RecordingOutputDestinations(
            addToHistory: { result, _ in
                try? FileManager.default.copyItem(at: result.fileURL, to: historyCopy)
                return (historyID, historyCopy)
            },
            showQuickAccess: { result, savedURL in
                #expect(savedURL == nil)
                shown = result
                return UUID()
            }
        ))
        let outcome = await router.route(fixture.result)
        #expect(outcome.savedURL == nil)
        #expect(outcome.quickAccessCardID != nil)
        #expect(shown?.fileURL == historyCopy)
        #expect(shown?.historyID == historyID)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: fixture.exportFolder.path))?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFolder.path))
    }

    @MainActor
    @Test func copyWithoutHistoryRetainsFileAndWritesURL() async throws {
        let fixture = try RouterFixture()
        defer { fixture.cleanup() }
        var shown = false
        let router = fixture.router(RecordingOutputDestinations(showQuickAccess: { _, _ in shown = true; return UUID() }))
        let outcome = await router.route(fixture.result, overriding: .copy)

        #expect(outcome.copiedToClipboard)
        #expect(!shown)
        #expect(outcome.historyID == nil)
        let kept = try #require(outcome.fileURL)
        #expect(kept.deletingLastPathComponent().standardizedFileURL == fixture.retainedFolder.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: kept.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.sessionFolder.path))
        let urls = fixture.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]
        let pasted = try #require(urls?.first)
        #expect(pasted.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: pasted.path))
    }

    // MARK: URLs

    @Test func recordScreenURL() throws {
        let command = try URLSchemeHandler.parse(#require(URL(string:
            "hakoshot://record-screen?x=100&y=100&width=640&height=360&start=true&duration=3&action=save&source=synthetic&countdown=0&out=/tmp/r.mp4"
        )))
        guard case let .record(kind, options) = command else {
            Issue.record("got \(command)")
            return
        }
        #expect(kind == .area)
        #expect(options.rect == CGRect(x: 100, y: 100, width: 640, height: 360))
        #expect(options.start)
        #expect(options.action == .save)
        #expect(options.autoStopAfter == 3)
        #expect(options.source == .synthetic)
        #expect(options.countdownSeconds == 0)
        #expect(options.outputURL?.path == "/tmp/r.mp4")
        #expect(options.format == nil)
        #expect(!options.studio)
    }

    @Test func recordScreenDefaultsAndModes() throws {
        #expect(try URLSchemeHandler.parse(#require(URL(string: "hakoshot://record-screen"))) == .record(.area))
        #expect(try URLSchemeHandler.parse(#require(URL(string: "hakoshot://record-screen?mode=window"))) == .record(.window))
        #expect(
            try URLSchemeHandler.parse(#require(URL(string: "hakoshot://record-screen?mode=fullscreen&display=2&format=gif&studio=true")))
                == .record(.fullscreen, RecordingCommandOptions(display: 2, format: .gif, studio: true))
        )
        #expect(try URLSchemeHandler.parse(#require(URL(string: "hakoshot://stop-recording"))) == .stopRecording)
    }

    @Test(arguments: [
        "hakoshot://record-screen?mode=region",
        "hakoshot://record-screen?format=webm",
        "hakoshot://record-screen?action=pin",
        "hakoshot://record-screen?x=1&y=2&width=3",
        "hakoshot://record-screen?display=0",
        "hakoshot://record-screen?duration=0",
        "hakoshot://record-screen?source=camera",
    ])
    func recordScreenRejects(_ string: String) throws {
        #expect(throws: URLSchemeError.self) { try URLSchemeHandler.parse(#require(URL(string: string))) }
    }

    @Test func debugURLs() throws {
        #expect(try URLSchemeHandler.parse(#require(URL(string: "hakoshot://debug-history-sample-video"))) == .debugHistorySampleVideo)
        #expect(
            try URLSchemeHandler.parse(#require(URL(string: "hakoshot://debug-quick-access-video-sample?format=gif&hover=1")))
                == .debugQuickAccessVideoSample(format: .gif, hover: true)
        )
        #expect(
            try URLSchemeHandler.parse(#require(URL(string: "hakoshot://debug-media-info?filepath=/tmp/a.mp4&out=/tmp/a.json")))
                == .debugMediaInfo(file: URL(fileURLWithPath: "/tmp/a.mp4"), out: URL(fileURLWithPath: "/tmp/a.json"))
        )
        let record = try URLSchemeHandler.parse(#require(URL(string: "hakoshot://debug-record?seconds=2&source=synthetic")))
        #expect(record == .debugRecord(RecordingDebug.Parameters(seconds: 2, source: .synthetic)))
    }

    @MainActor
    @Test func recordScreenShortcutDefaultAndMenu() throws {
        let name = try #require(ShortcutBinding.name(for: .record(.area)))
        #expect(name == .recordScreen)
        let shortcut = try #require(name.initialShortcut)
        #expect(shortcut.key == .nine)
        #expect(shortcut.modifiers == [.command, .shift])
        #expect(ShortcutBinding.name(for: .togglePauseRecording)?.initialShortcut == nil)

        func titles(_ state: MenuState) -> [String] {
            MenuBuilder.entries(for: state).compactMap {
                if case let .command(title, _, _, _, _, _, _) = $0 { return title }
                return nil
            }
        }
        #expect(titles(MenuState()).contains("Record Screen"))
        #expect(!titles(MenuState()).contains("Stop Recording"))
        var recording = MenuState()
        recording.isRecording = true
        #expect(titles(recording).contains("Stop Recording"))
        #expect(!titles(recording).contains("Record Screen"))
    }
}

/// A fake finished recording inside a fake session folder, plus scratch settings.
@MainActor
private final class RouterFixture {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hako-router-\(UUID().uuidString)")
    let settings = PostCaptureFixture.ScratchSettings()
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("hako-router-test-\(UUID().uuidString)"))
    var sessionFolder: URL { dir.appending(path: "session") }
    var exportFolder: URL { dir.appending(path: "export") }
    var retainedFolder: URL { dir.appending(path: "retained") }
    let result: RecordingResult

    init() throws {
        let session = dir.appending(path: "session")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        let file = session.appending(path: RecordingFinalizer.outputFileName)
        try Data("not really an mp4".utf8).write(to: file)
        let raw = RawRecording(
            id: UUID(), sessionFolder: session,
            target: .area(GlobalRect(x: 0, y: 0, width: 10, height: 10), displayID: CGMainDisplayID()),
            profile: .classic, pixelSize: CGSize(width: 20, height: 20), pointSize: CGSize(width: 10, height: 10),
            scale: 2, fps: 60, duration: 1, startDate: Date(timeIntervalSince1970: 1_726_000_000)
        )
        result = RecordingResult(
            fileURL: file, format: .video, duration: 1, pixelSize: CGSize(width: 20, height: 20),
            thumbnail: PostCaptureFixture.image(), date: raw.startDate, targetKind: .area, raw: raw
        )
        settings.settings.set(dir.appending(path: "export").path, for: .outputSaveFolderPath)
    }

    func router(_ destinations: RecordingOutputDestinations) -> RecordingOutputRouter {
        RecordingOutputRouter(
            settings: settings.settings,
            clipboardWriter: ClipboardWriter(pasteboard: pasteboard),
            destinations: destinations,
            retainedFolder: retainedFolder,
            dragFolder: dir.appending(path: "drag")
        )
    }

    func cleanup() {
        settings.cleanup()
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: dir)
    }
}
