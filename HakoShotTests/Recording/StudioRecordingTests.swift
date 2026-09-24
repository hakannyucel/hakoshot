import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R6.3 / R6.I: Studio Mode recordings become `.hakostudio` packages
/// (History `.studio` entry, auto zoom, recovery), plus the Studio URL,
/// menu, Quick Access and History wiring.
@Suite("Studio recording", .serialized)
@MainActor
struct StudioRecordingTests {
    // MARK: Engine

    @Test func studioFPSFollowsTheDisplayUpTo60() {
        let studio = RecordingRequest(target: .display(1), profile: .studio)
        #expect(RecordingEngine.effectiveFPS(studio, displayRefreshRate: 120) == 60)
        #expect(RecordingEngine.effectiveFPS(studio, displayRefreshRate: 50) == 50)
        #expect(RecordingEngine.effectiveFPS(studio, displayRefreshRate: 0) == 60)
        #expect(RecordingEngine.effectiveFPS(studio) == 60)
        var classic = RecordingRequest(target: .display(1))
        classic.options.fps = 30
        #expect(RecordingEngine.effectiveFPS(classic, displayRefreshRate: 120) == 30)
        #expect(RecordingEngine.effectiveQuality(studio) == .ultra)
    }

    @Test func sessionMarkerRoundTripsAndDecidesStudio() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HakoShotMarker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = RecordingSessionMarker(
            profile: .studio, format: .video, rect: CGRect(x: 10, y: 20, width: 320, height: 180), displayID: 1,
            scale: 2, pixelWidth: 640, pixelHeight: 360, fps: 60, showsCursor: false, audioTracks: [.microphone, .system],
            startDate: Date(timeIntervalSince1970: 1_726_000_000)
        )
        marker.write(toSessionFolder: folder)
        let read = try #require(RecordingSessionMarker.read(inSessionFolder: folder))
        #expect(read == marker)
        #expect(read.fallbackMetadata.geometry.rect == CGRect(x: 10, y: 20, width: 320, height: 180))
        #expect(read.fallbackMetadata.cursorBakedIn == false)

        #expect(RecordingRecovery.isStudioSession(marker: marker, metadata: nil, hasCamera: false))
        var classic = marker
        classic.profile = .classic
        // session.json wins over the old heuristics (every recording has cursor.bin now).
        #expect(!RecordingRecovery.isStudioSession(marker: classic, metadata: nil, hasCamera: false))
        #expect(!RecordingRecovery.isStudioSession(marker: nil, metadata: nil, hasCamera: false))
        #expect(RecordingRecovery.isStudioSession(marker: nil, metadata: nil, hasCamera: true))
    }

    // MARK: Package

    @Test(.timeLimit(.minutes(1)))
    func studioStopBecomesAPackageInHistoryWithAutoZoom() async throws {
        let scratch = try RecordingRecoveryTests.Scratch()
        defer { scratch.cleanup() }
        let engine = RecordingEngine(sessionsRoot: scratch.engineRoot)
        var request = RecordingRequest(
            target: .area(GlobalRect(x: 0, y: 0, width: 320, height: 180), displayID: CGMainDisplayID()),
            profile: .studio,
            source: .synthetic
        )
        request.options.showsCursor = true
        _ = try await engine.start(request)
        try #require(await engine.waitForFirstFrame(), "no frame within 5 s")
        try await Task.sleep(for: .seconds(2))
        let raw = try await engine.stop()
        #expect(raw.profile == .studio)
        #expect(raw.fps == 60)

        // Clicks as the EventRecorder would merge them (one mouse-down at 1 s).
        let eventsURL = try #require(raw.eventsURL)
        var metadata = try RecordingMetadata(jsonData: Data(contentsOf: eventsURL))
        #expect(metadata.cursorBakedIn == false)
        metadata.clicks = [
            RecordingClickEvent(time: 1.0, x: 80, y: 45, isDown: true),
            RecordingClickEvent(time: 1.08, x: 80, y: 45, isDown: false),
        ]
        try metadata.jsonData().write(to: eventsURL)
        // A short cursor track.
        let samples = (0..<30).map { CursorSample(time: Double($0) / 30, x: Float(10 + $0), y: 20, shapeIndex: 0, flags: []) }
        try CursorTrackCodec.encode(samples).write(to: raw.sessionFolder.appending(path: RawRecording.FileName.cursor))

        let history = HistoryStore(rootURL: scratch.history)
        var opened: [URL] = []
        let router = RecordingOutputRouter(settings: .shared, destinations: RecordingOutputDestinations(
            newStudioPackage: { date in
                let id = UUID()
                guard let url = await history.newStudioPackageURL(id: id, date: date) else { return nil }
                return (id, url)
            },
            addStudioToHistory: { id, output, raw in
                await history.addStudioProject(
                    id: id, date: raw.startDate, preview: output.preview, pixelSize: output.project.source.pixelSize,
                    scale: Double(raw.scale), duration: output.project.source.duration
                ) != nil
            },
            openStudio: { opened.append($0) }
        ))
        let defaults = StudioProjectDefaults(autoZoom: true, defaultZoom: 2.5)
        let outcome = try await router.routeStudio(raw, defaults: defaults)

        #expect(opened == [outcome.packageURL])
        #expect(!FileManager.default.fileExists(atPath: raw.sessionFolder.path))
        let contents = try StudioProjectFile.read(from: outcome.packageURL)
        let project = contents.project
        #expect(project.source.cursorBakedIn == false)
        #expect(project.source.media.events != nil)
        #expect(project.source.media.cursor != nil)
        #expect(project.source.media.camera == nil)
        #expect(project.source.pixelWidth > 0)
        #expect(abs(project.source.duration - raw.duration) < 0.2)
        #expect(project.zoom.defaultScale == 2.5)
        #expect(!project.zoom.segments.isEmpty)
        #expect(project.zoom.segments.allSatisfy { !$0.isManual && $0.start <= 1.0 && $0.end >= 1.0 })
        #expect(StudioProjectFile.readCursorTrack(for: project, in: outcome.packageURL).count == 30)
        #expect(StudioProjectFile.readPreview(from: outcome.packageURL) != nil)
        // Regular (defragmented) movie, still playable.
        let screen = StudioProjectFile.mediaURL(project.source.media.screen, in: outcome.packageURL)
        #expect(try await AVURLAsset(url: screen).load(.isPlayable))

        let id = try #require(outcome.historyID)
        let item = try #require(await history.item(id: id))
        #expect(item.kind == .studio)
        #expect(item.mediaFileName == nil)
        #expect(history.studioPackageURL(for: item)?.standardizedFileURL == outcome.packageURL.standardizedFileURL)
        #expect(await history.thumbnail(for: item) != nil)
        #expect(HistoryCardAction.menu(for: item) == [.openInStudio, .copy, nil, .delete])
        #expect(!HistoryCardAction.canConvertToGIF(item))

        // Deleting the entry deletes the package.
        await history.remove(id: id)
        #expect(!FileManager.default.fileExists(atPath: outcome.packageURL.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func crashedStudioSessionIsRecoveredAsAPackage() async throws {
        let scratch = try RecordingRecoveryTests.Scratch()
        defer { scratch.cleanup() }
        let id = try await scratch.makeCrashedSession(profile: .studio)

        let history = HistoryStore(rootURL: scratch.history)
        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: history, fallbackFolder: scratch.fallback,
            studioFolder: scratch.base.appending(path: "Studio"), minimumIdle: 0
        )
        let recovered = try #require(report.recovered.first)
        #expect(recovered.sessionID == id)
        #expect(recovered.wasStudio)
        let package = try #require(recovered.studioPackageURL)
        let project = try StudioProjectFile.read(from: package).project
        #expect(project.source.cursorBakedIn == false)
        #expect(project.source.duration > 0)
        // No events.json after a crash: the geometry comes from session.json.
        #expect(project.source.pointWidth == 320)
        let item = try #require(recovered.historyItem)
        #expect(item.kind == .studio)
        #expect(recovered.result.studioProjectURL == package)
        #expect(!FileManager.default.fileExists(atPath: scratch.sessions.appending(path: id.uuidString).path))
    }

    @Test(.timeLimit(.minutes(1)))
    func crashedStudioSessionWithHistoryOffGoesToTheStudioFolder() async throws {
        let scratch = try RecordingRecoveryTests.Scratch()
        defer { scratch.cleanup() }
        _ = try await scratch.makeCrashedSession(profile: .studio)
        let studioFolder = scratch.base.appending(path: "Studio")
        let history = HistoryStore(rootURL: scratch.history, configuration: { HistoryConfiguration(isEnabled: false, retention: .oneMonth) })
        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: history, fallbackFolder: scratch.fallback,
            studioFolder: studioFolder, minimumIdle: 0
        )
        let package = try #require(report.recovered.first?.studioPackageURL)
        #expect(package.deletingLastPathComponent().standardizedFileURL == studioFolder.standardizedFileURL)
        #expect(package.pathExtension == "hakostudio")
        #expect(report.recovered.first?.historyItem == nil)
    }

    @Test func defaultBackgroundSetting() {
        #expect(StudioRecordingFinalizer.background(fromJSON: "") == StudioCanvas.defaultBackground)
        #expect(StudioRecordingFinalizer.background(fromJSON: "not json") == StudioCanvas.defaultBackground)
        var style = StudioCanvas.defaultBackground
        style.fill = .solid(RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))
        let json = String(decoding: try! JSONEncoder().encode(style), as: UTF8.self)
        #expect(StudioRecordingFinalizer.background(fromJSON: json) == style)
    }

    @Test func fallbackPackageNamesNeverCollide() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "HakoShotStudioNames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let date = Date(timeIntervalSince1970: 1_726_000_000)
        let first = RecordingOutputRouter.studioFallbackURL(date: date, folder: folder)
        #expect(first.lastPathComponent.hasPrefix("Studio Recording "))
        #expect(first.pathExtension == "hakostudio")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        let second = RecordingOutputRouter.studioFallbackURL(date: date, folder: folder)
        #expect(second != first)
        #expect(second.lastPathComponent.contains("(2)"))
    }

    // MARK: Wiring

    @Test func openStudioURLs() throws {
        #expect(try URLSchemeHandler.parse(URL(string: "hakoshot://open-studio")!) == .openStudio(nil))
        #expect(try URLSchemeHandler.parse(URL(string: "hakoshot://open-studio?filepath=/tmp/a.hakostudio")!)
            == .openStudio(URL(fileURLWithPath: "/tmp/a.hakostudio")))
        #if DEBUG
        let frame = try URLSchemeHandler.parse(URL(string: "hakoshot://debug-render-studio-frame?project=/tmp/p.hakostudio&time=1&out=/tmp/f.png")!)
        #expect(frame == .debugStudio(.renderFrame(project: URL(fileURLWithPath: "/tmp/p.hakostudio"), time: 1,
                                                    out: URL(fileURLWithPath: "/tmp/f.png"), height: nil)))
        #expect(throws: URLSchemeError.self) { try URLSchemeHandler.parse(URL(string: "hakoshot://debug-render-studio-frame?project=/tmp/p")!) }
        guard case .debugBenchmarkExport = try URLSchemeHandler.parse(URL(string: "hakoshot://debug-benchmark-export?out=/tmp/b.json")!) else {
            Issue.record("debug-benchmark-export not parsed")
            return
        }
        #expect(throws: URLSchemeError.self) { try URLSchemeHandler.parse(URL(string: "hakoshot://debug-benchmark-export")!) }
        #expect(try URLSchemeHandler.parse(URL(string: "hakoshot://debug-close-studio-windows")!) == .debugCloseStudioWindows)
        let crash = try URLSchemeHandler.parse(URL(string: "hakoshot://debug-crash-during-recording?studio=1")!)
        #expect(crash == .debugCrashDuringRecording(RecoveryDebug.CrashParameters(studio: true)))
        #endif
    }

    @Test func menuOffersOpenStudioProject() {
        let titles = MenuBuilder.entries(for: MenuState()).compactMap { entry -> String? in
            if case let .command(title, command, _, _, _, _, _) = entry, command == .openStudio(nil) { return title }
            return nil
        }
        #expect(titles == ["Open Studio Project…"])
    }

    @Test func studioPackagesOpenInStudio() {
        #expect(AppCoordinator.isStudioPackage(URL(fileURLWithPath: "/tmp/Demo.hakostudio")))
        #expect(AppCoordinator.isStudioPackage(URL(fileURLWithPath: "/tmp/Demo.HAKOSTUDIO")))
        #expect(!AppCoordinator.isStudioPackage(URL(fileURLWithPath: "/tmp/Demo.mp4")))
        #expect(!AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/Demo.hakostudio")))
    }

    @Test func quickAccessOffersOpenInStudioOnVideosOnly() {
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let video = RecordingResult(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), format: .video, duration: 1,
                                    pixelSize: CGSize(width: 1, height: 1), thumbnail: image, targetKind: .area)
        var gif = video
        gif.format = .gif
        #expect(QuickAccessCardControls(item: .video(video), canOpenInStudio: true).openInStudio)
        #expect(!QuickAccessCardControls(item: .video(video)).openInStudio)
        #expect(!QuickAccessCardControls(item: .video(gif), canOpenInStudio: true).openInStudio)
    }

    @Test func historyMenuOffersOpenInStudioForVideos() {
        let video = HistoryItem(date: .now, kind: .recording, pixelWidth: 10, pixelHeight: 10, scale: 1,
                                imageFileName: "a.png", thumbnailFileName: "a.jpg", mediaFileName: "a.mp4", mediaFormat: .video)
        let gif = HistoryItem(date: .now, kind: .gif, pixelWidth: 10, pixelHeight: 10, scale: 1,
                              imageFileName: "b.png", thumbnailFileName: "b.jpg", mediaFileName: "b.gif", mediaFormat: .gif)
        #expect(HistoryCardAction.menu(for: video).contains(.openInStudio))
        #expect(HistoryCardAction.canOpenInStudio(video))
        #expect(!HistoryCardAction.menu(for: gif).contains(.openInStudio))
        #expect(HistoryCardAction.openInStudio.title(for: video) == "Open in Studio")
    }
}
