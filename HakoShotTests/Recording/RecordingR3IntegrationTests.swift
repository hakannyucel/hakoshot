import AppKit
import Foundation
import HakoKit
import ImageIO
import Testing
@testable import HakoShot

/// R3.I: URL commands, router decisions for GIFs and the video editor,
/// Settings (GIF section, After capture matrix), Convert to GIF, Quick
/// Access progress and the History card menu.
@Suite("R3 integration", .serialized)
struct RecordingR3IntegrationTests {
    private func parse(_ string: String) throws -> AppCommand {
        try URLSchemeHandler.parse(try #require(URL(string: string)))
    }

    private func parseError(_ string: String) throws -> URLSchemeError? {
        do {
            _ = try URLSchemeHandler.parse(try #require(URL(string: string)))
            return nil
        } catch {
            return error as? URLSchemeError
        }
    }

    // MARK: URLs

    @Test func openVideoEditorURL() throws {
        #expect(try parse("hakoshot://open-video-editor") == .openVideoEditor(nil))
        #expect(try parse("hakoshot://open-video-editor?filepath=/tmp/a.mp4") == .openVideoEditor(URL(fileURLWithPath: "/tmp/a.mp4")))
        #expect(try parse("hakoshot://open-video-editor?path=file:///tmp/b.mov") == .openVideoEditor(URL(fileURLWithPath: "/tmp/b.mov")))
    }

    @Test func convertToGIFURL() throws {
        let file = URL(fileURLWithPath: "/tmp/a.mp4")
        #expect(try parse("hakoshot://convert-to-gif?filepath=/tmp/a.mp4") == .convertToGIF(file))
        #expect(try parse("hakoshot://convert-to-gif?filepath=/tmp/a.mp4&action=save") == .convertToGIF(file, action: .save))
        #expect(try parse("hakoshot://convert-to-gif?filepath=/tmp/a.mp4&action=COPY") == .convertToGIF(file, action: .copy))
        #expect(try parseError("hakoshot://convert-to-gif") == .invalidParameter(name: "filepath", value: ""))
        #expect(try parseError("hakoshot://convert-to-gif?filepath=/tmp/a.mp4&action=pin") == .invalidParameter(name: "action", value: "pin"))
        #expect(AppCommand.convertToGIF(file, action: .save).description == "convertToGIF(/tmp/a.mp4, action=save)")
    }

    #if DEBUG
    @Test func debugURLs() throws {
        let recipe = #"{"trim":{"start":2,"end":7}}"#.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        guard case let .debugRender(render) = try parse("hakoshot://debug-render?filepath=/tmp/a.mp4&recipe=\(recipe)&out=/tmp/b.mp4&passthrough=0") else {
            Issue.record("debug-render")
            return
        }
        #expect(render.source == URL(fileURLWithPath: "/tmp/a.mp4"))
        #expect(render.out == URL(fileURLWithPath: "/tmp/b.mp4"))
        #expect(render.recipe.trim == EditTimeRange(start: 2, end: 7))
        #expect(!render.allowsPassthrough)
        #expect(try parseError("hakoshot://debug-render?filepath=/tmp/a.mp4") != nil)
        #expect(try parseError("hakoshot://debug-render?filepath=/tmp/a.mp4&out=/tmp/b.mp4&recipe=%7Bnope") != nil)

        guard case let .debugVideoEditor(snapshot) = try parse("hakoshot://debug-video-editor?filepath=/tmp/a.mp4&snapshot=/tmp/s.png&t=1.5") else {
            Issue.record("debug-video-editor")
            return
        }
        #expect(snapshot.snapshot == URL(fileURLWithPath: "/tmp/s.png"))
        #expect(snapshot.time == 1.5)
        #expect(try parseError("hakoshot://debug-video-editor") == .invalidParameter(name: "filepath", value: ""))

        guard case let .debugVideoEditorApply(apply) = try parse("hakoshot://debug-video-editor-apply?filepath=/tmp/a.mp4&recipe=\(recipe)&out=/tmp/c.mp4") else {
            Issue.record("debug-video-editor-apply")
            return
        }
        #expect(apply.out == URL(fileURLWithPath: "/tmp/c.mp4"))
        #expect(apply.recipeJSON == #"{"trim":{"start":2,"end":7}}"#)

        #expect(try parse("hakoshot://debug-crash-during-recording?seconds=3") == .debugCrashDuringRecording(RecoveryDebug.CrashParameters(seconds: 3)))
        #expect(try parse("hakoshot://debug-recover-recordings?out=/tmp/r.json") == .debugRecoverRecordings(out: URL(fileURLWithPath: "/tmp/r.json")))
        #expect(try parse("hakoshot://debug-recover-recordings") == .debugRecoverRecordings(out: nil))
    }
    #endif

    // MARK: Router decisions

    @Test func routerOpensEditorOnlyForVideos() {
        let config = AfterRecordingConfig(showQuickAccess: true, copyToClipboard: false, saveToDisk: false, openVideoEditor: true)
        #expect(RecordingOutputDecision.make(config: config, override: nil, copyAlsoSaves: false, format: .video).openVideoEditor)
        #expect(!RecordingOutputDecision.make(config: config, override: nil, copyAlsoSaves: false, format: .gif).openVideoEditor)
        #expect(RecordingOutputDecision.make(config: config, override: nil, copyAlsoSaves: false, format: .gif).showQuickAccess)
        // An explicit action never opens the editor.
        #expect(!RecordingOutputDecision.make(config: config, override: .save, copyAlsoSaves: false, format: .video).openVideoEditor)
    }

    @Test func convertedGIFsGetACardOnly() {
        let decision = RecordingOutputDecision.make(config: GIFConversion.deliveryConfig, override: nil, copyAlsoSaves: true, format: .gif)
        #expect(decision == RecordingOutputDecision(showQuickAccess: true))
        #expect(RecordingOutputDecision.make(config: GIFConversion.deliveryConfig, override: .save, copyAlsoSaves: false, format: .gif)
            == RecordingOutputDecision(save: true))
    }

    @MainActor
    @Test func routeCallsVideoEditorDestination() async throws {
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        let dir = FileManager.default.temporaryDirectory.appending(path: "hako-r3i-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        scratch.settings.set(true, for: .afterRecordingOpenVideoEditor)
        scratch.settings.set(false, for: .afterRecordingShowQuickAccess)

        var opened: [URL] = []
        let router = RecordingOutputRouter(
            settings: scratch.settings,
            destinations: RecordingOutputDestinations(openVideoEditor: { result, _ in opened.append(result.fileURL) }),
            retainedFolder: dir.appending(path: "retained"),
            dragFolder: dir.appending(path: "drag")
        )
        for format in [RecordingFormat.video, .gif] {
            let file = dir.appending(path: "clip.\(format.pathExtension)")
            try Data("x".utf8).write(to: file)
            let result = RecordingResult(
                fileURL: file, format: format, duration: 1, pixelSize: CGSize(width: 8, height: 6),
                thumbnail: PostCaptureFixture.image(), targetKind: .area
            )
            let outcome = await router.route(result)
            #expect(outcome.quickAccessCardID == nil)
        }
        #expect(opened.map(\.pathExtension) == ["mp4"])
    }

    // MARK: Settings

    @MainActor
    @Test func gifOptionsFollowSettings() {
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        #expect(GIFConversion.options(settings: scratch.settings) == GIFExportOptions(fps: 15, width: 800, optimize: true, quality: 0.8))
        scratch.settings.set(24, for: .gifFrameRate)
        scratch.settings.set(RecordingSettingChoices.gifOriginalWidth, for: .gifWidth)
        scratch.settings.set(false, for: .gifOptimize)
        scratch.settings.set(0.25, for: .gifQuality)
        #expect(GIFConversion.options(settings: scratch.settings) == GIFExportOptions(fps: 24, width: 0, optimize: false, quality: 0.25))
    }

    @Test func gifSectionChoices() {
        #expect(GIFSettingsSection.frameRateChoices(current: 15) == [5, 10, 15, 20, 24, 30])
        #expect(GIFSettingsSection.frameRateChoices(current: 12) == [5, 10, 12, 15, 20, 24, 30])
        #expect(GIFSettingsSection.widthChoices(current: 800) == [400, 600, 800, 1000, 1200, 0])
        #expect(GIFSettingsSection.widthChoices(current: 0) == [400, 600, 800, 1000, 1200, 0])
        #expect(GIFSettingsSection.widthChoices(current: 720) == [400, 600, 720, 800, 1000, 1200, 0])
        #expect(GIFSettingsSection.widthTitle(800) == "800 × auto")
        #expect(GIFSettingsSection.widthTitle(0) == "Original")
    }

    @MainActor
    @Test func afterCaptureMatrixBindsBothColumns() {
        let rows = AfterCaptureMatrixRow.rows
        #expect(rows.map(\.title) == [
            "Show Quick Access Overlay", "Copy file to clipboard", "Save", "Open Annotate tool", "Pin to the screen", "Open Video Editor",
        ])
        #expect(rows.map { $0.recording?.name } == [
            SettingsKey<Bool>.afterRecordingShowQuickAccess.name, SettingsKey<Bool>.afterRecordingCopy.name,
            SettingsKey<Bool>.afterRecordingSave.name, nil, nil, SettingsKey<Bool>.afterRecordingOpenVideoEditor.name,
        ])
        #expect(rows.map { $0.screenshot?.name } == [
            SettingsKey<Bool>.afterCaptureShowQuickAccess.name, SettingsKey<Bool>.outputCopyToClipboardOnCapture.name,
            SettingsKey<Bool>.outputSaveToDiskOnCapture.name, SettingsKey<Bool>.afterCaptureOpenEditor.name,
            SettingsKey<Bool>.afterCapturePin.name, nil,
        ])
        // Recording defaults (plan §5.1): Quick Access only.
        #expect(rows.compactMap { $0.recording?.defaultValue } == [true, false, false, false])
        // The column writes what the router reads.
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        for row in rows { if let key = row.recording { scratch.settings.set(true, for: key) } }
        #expect(AfterRecordingConfig(settings: scratch.settings)
            == AfterRecordingConfig(showQuickAccess: true, copyToClipboard: true, saveToDisk: true, openVideoEditor: true))
    }

    // MARK: Convert to GIF

    @Test func largeGIFEstimate() {
        let small = GIFConversion.estimatedBytes(duration: 3, pixelWidth: 1280, pixelHeight: 720, options: .default)
        #expect(small > 0)
        #expect(!GIFConversion.isLarge(small))
        // 60 s at 30 fps, original 2560×1440: well over 50 MB.
        let large = GIFConversion.estimatedBytes(
            duration: 60, pixelWidth: 2560, pixelHeight: 1440, options: GIFExportOptions(fps: 30, width: 0, optimize: false, quality: 1)
        )
        #expect(GIFConversion.isLarge(large))
    }

    #if DEBUG
    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func convertsVideoToGIFResult() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hako-r3i-gif-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = try await QuickAccessVideoDebug.makeSampleResult(
            format: .video, seconds: 2, pixelSize: CGSize(width: 640, height: 360), in: dir
        )
        let destination = GIFConversion.newWorkFileURL(in: dir)
        let result = try await GIFConversion.convert(
            source: video.fileURL, options: GIFExportOptions(fps: 10, width: 400, optimize: false, quality: 0.5),
            to: destination, targetKind: .window
        )
        #expect(result.format == .gif)
        #expect(result.fileURL == destination)
        #expect(result.pixelSize == CGSize(width: 400, height: 225))
        #expect(abs(result.duration - 2) < 0.15)
        #expect(result.targetKind == .window)
        #expect(result.thumbnail.width <= Int(RecordingThumbnailer.maxDimension))
        let source = try #require(CGImageSourceCreateWithURL(destination as CFURL, nil))
        #expect(CGImageSourceGetCount(source) == 20)
    }
    #endif

    @Test func unreadableGIFThrows() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "hako-r3i-\(UUID().uuidString).gif")
        try Data("nope".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(throws: GIFConversion.GIFReadError.self) { try GIFConversion.result(forGIF: file) }
    }

    // MARK: Quick Access, History, files

    #if DEBUG
    @MainActor
    @Test func quickAccessShowsConversionProgress() async throws {
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        let dir = FileManager.default.temporaryDirectory.appending(path: "hako-r3i-qa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let controller = QuickAccessController(settings: scratch.settings, animates: false)
        var requests: [QuickAccessRecordingRequest] = []
        controller.onConvertToGIF = { requests.append($0) }
        controller.onEditRecording = { _ in }
        let video = try await QuickAccessVideoDebug.makeSampleResult(format: .video, seconds: 1, pixelSize: CGSize(width: 64, height: 36), in: dir)
        let id = controller.show(recording: video)
        defer { controller.closeAll() }

        controller.perform(.convertToGIF, on: id)
        #expect(requests.count == 1)
        #expect(requests.first?.cardID == id)
        #expect(controller.setConversionProgress(0.4, for: id))
        #expect(controller.conversionProgress(for: id) == 0.4)
        // Busy: a second ⌘G is ignored.
        controller.perform(.convertToGIF, on: id)
        #expect(requests.count == 1)
        #expect(controller.setConversionProgress(nil, for: id))
        #expect(controller.conversionProgress(for: id) == nil)
        #expect(!controller.setConversionProgress(0.5, for: UUID()))
    }
    #endif

    @Test func historyCardMenu() {
        func item(_ kind: HistoryCaptureKind, format: HistoryMediaFormat? = nil) -> HistoryItem {
            var item = HistoryItem(
                date: .now, kind: kind, pixelWidth: 10, pixelHeight: 10, scale: 1,
                imageFileName: "a.png", thumbnailFileName: "a-t.png"
            )
            item.mediaFormat = format
            return item
        }
        #expect(HistoryCardAction.menu(for: item(.area)) == [.restore, .copy, nil, .edit, .pin, nil, .delete])
        #expect(HistoryCardAction.menu(for: item(.recording, format: .video)) == [.restore, .copy, nil, .edit, .openInStudio, .convertToGIF, nil, .delete])
        #expect(HistoryCardAction.menu(for: item(.gif, format: .gif)) == [.restore, .copy, nil, .delete])
        #expect(HistoryCardAction.canConvertToGIF(item(.recording, format: .video)))
        #expect(!HistoryCardAction.canConvertToGIF(item(.gif, format: .gif)))
        #expect(!HistoryCardAction.canConvertToGIF(item(.area)))
        #expect(HistoryCardAction.edit.title(for: item(.recording)) == "Open in Video Editor")
        #expect(HistoryCardAction.edit.title(for: item(.area)) == "Open in Editor")
    }

    @Test func moviesOpenInTheVideoEditor() {
        #expect(AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/a.mp4")))
        #expect(AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/a.MOV")))
        #expect(AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/a.m4v")))
        #expect(!AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/a.gif")))
        #expect(!AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/a.png")))
        #expect(!AppCoordinator.opensInVideoEditor(URL(fileURLWithPath: "/tmp/a.hakoshot")))
        #expect(!AppCoordinator.opensInVideoEditor(URL(string: "https://example.com/a.mp4")!))
    }

    @Test func menuHasOpenVideo() {
        let titles = MenuBuilder.entries(for: MenuState()).compactMap { entry -> String? in
            if case let .command(title, command, _, _, _, _, _) = entry, command == .openVideoEditor(nil) { return title }
            return nil
        }
        #expect(titles == ["Open Video…"])
    }
}
