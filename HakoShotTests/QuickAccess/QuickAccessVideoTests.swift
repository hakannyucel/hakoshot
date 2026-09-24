import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Video / GIF cards (kayit-teknik-plan §4.15, R0.5).
enum VideoCardFixture {
    static let date = Date(timeIntervalSince1970: 1_726_000_000)

    /// A `RecordingResult` whose `fileURL` is a small placeholder file in `directory`
    /// (copy / save only move bytes, they never decode the video).
    static func recording(
        format: RecordingFormat = .video,
        duration: Double = 2,
        in directory: URL,
        historyID: UUID? = nil
    ) throws -> RecordingResult {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "\(UUID().uuidString).\(format.pathExtension)")
        try Data("fake \(format.pathExtension) bytes".utf8).write(to: url)
        return RecordingResult(
            fileURL: url,
            format: format,
            duration: duration,
            pixelSize: CGSize(width: 1280, height: 720),
            thumbnail: PostCaptureFixture.image(pointWidth: 16, pointHeight: 9, scale: 1),
            date: date,
            targetKind: .area,
            historyID: historyID
        )
    }
}

@Suite("QuickAccess video model")
struct QuickAccessVideoModelTests {
    @Test func videoItemBuildsAVideoCard() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let recording = try VideoCardFixture.recording(duration: 42.4, in: dir.url)
        let card = QuickAccessCard(item: .video(recording), savedURL: nil, width: 200)

        #expect(card.item.isVideo)
        #expect(card.result == nil)
        #expect(card.recording?.fileURL == recording.fileURL)
        #expect(card.recording?.format == .video)
        // 16:9 → 200 × 113 (aspect from the video's pixel size, not the thumbnail's).
        #expect(card.size == CGSize(width: 200, height: 113))
        #expect(card.durationText == "0:42")
        #expect(card.item.contentSize == CGSize(width: 1280, height: 720))
        #expect(card.item.date == VideoCardFixture.date)
    }

    @Test func videoCardsHidePinAndAnnotateAndR3SlotsUntilHooksExist() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let video = QuickAccessItem.video(try VideoCardFixture.recording(in: dir.url))
        let gif = QuickAccessItem.video(try VideoCardFixture.recording(format: .gif, in: dir.url))

        let plain = QuickAccessCardControls(item: video)
        #expect(!plain.pin && !plain.annotate)
        #expect(!plain.editVideo && !plain.convertToGIF)
        #expect(plain.durationBadge)

        let r3 = QuickAccessCardControls(item: video, canEditVideo: true, canConvertToGIF: true)
        #expect(r3.editVideo && r3.convertToGIF)
        #expect(!r3.pin && !r3.annotate)

        // A GIF can't be converted to GIF.
        let gifControls = QuickAccessCardControls(item: gif, canEditVideo: true, canConvertToGIF: true)
        #expect(!gifControls.convertToGIF)
        #expect(gifControls.editVideo)

        // Image cards keep Pin + Annotate and get no badge.
        let image = QuickAccessCardControls(item: .image(PostCaptureFixture.captureResult()), canEditVideo: true, canConvertToGIF: true)
        #expect(image.pin && image.annotate)
        #expect(!image.editVideo && !image.convertToGIF && !image.durationBadge)
    }

    @Test func imageCardIsUnchanged() {
        let result = PostCaptureFixture.captureResult(pointWidth: 800, pointHeight: 500, scale: 1)
        let card = QuickAccessCard(result: result, savedURL: nil, width: 200)
        #expect(!card.item.isVideo)
        #expect(card.result != nil)
        #expect(card.recording == nil)
        #expect(card.durationText == nil)
        #expect(card.size == CGSize(width: 200, height: 125))
    }

    @Test func durationFormat() {
        #expect(QuickAccessDurationFormat.string(seconds: 0) == "0:00")
        #expect(QuickAccessDurationFormat.string(seconds: 2) == "0:02")
        #expect(QuickAccessDurationFormat.string(seconds: 2.97) == "0:03")
        #expect(QuickAccessDurationFormat.string(seconds: 42.4) == "0:42")
        #expect(QuickAccessDurationFormat.string(seconds: 62) == "1:02")
        #expect(QuickAccessDurationFormat.string(seconds: 600) == "10:00")
        #expect(QuickAccessDurationFormat.string(seconds: 3723) == "1:02:03")
        #expect(QuickAccessDurationFormat.string(seconds: -3) == "0:00")
        #expect(QuickAccessDurationFormat.string(seconds: .nan) == "0:00")
    }

    @Test func modeTokensAndGIFShortcut() {
        #expect(RecordingTargetKind.area.fileNameToken == "area")
        #expect(RecordingTargetKind.window.fileNameToken == "window")
        #expect(RecordingTargetKind.pickDisplay.fileNameToken == "fullscreen")
        #expect(QuickAccessKeyMap.action(keyCode: 0, characters: "g", modifiers: .command) == .convertToGIF)
        #expect(QuickAccessKeyMap.action(keyCode: 0, characters: "g", modifiers: [.command, .shift]) == nil)
    }
}

@Suite("RecordingFileExport")
struct RecordingFileExportTests {
    @Test func saveNamesUseTheTemplateAndMP4Extension() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let recording = try VideoCardFixture.recording(in: dir.url.appending(path: "src"))
        let name = RecordingFileExport.fileName(for: recording, template: .default)
        #expect(name.hasPrefix("HakoShot "))
        #expect(name.hasSuffix(".mp4"))
        let gif = try VideoCardFixture.recording(format: .gif, in: dir.url.appending(path: "src"))
        #expect(RecordingFileExport.fileName(for: gif, template: .default).hasSuffix(".gif"))

        // %mode uses the recording target.
        let modeName = RecordingFileExport.fileName(for: recording, template: FileNameTemplate(pattern: "rec %mode"))
        #expect(modeName == "rec area.mp4")
    }

    @Test func copyToFolderNeverOverwrites() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let recording = try VideoCardFixture.recording(in: dir.url.appending(path: "src"))
        let out = dir.url.appending(path: "out")
        let first = try RecordingFileExport.copy(recording, toFolder: out, template: .default)
        let second = try RecordingFileExport.copy(recording, toFolder: out, template: .default)
        #expect(first != second)
        #expect(first.pathExtension == "mp4")
        #expect(second.deletingPathExtension().lastPathComponent.hasSuffix(" (2)"))
        #expect(try Data(contentsOf: second) == Data(contentsOf: recording.fileURL))
        // The source (history copy) stays.
        #expect(FileManager.default.fileExists(atPath: recording.fileURL.path))
    }

    @Test func saveAsReplacesAConfirmedFile() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let recording = try VideoCardFixture.recording(in: dir.url.appending(path: "src"))
        let target = dir.url.appending(path: "chosen.mp4")
        try Data("old".utf8).write(to: target)
        try RecordingFileExport.copy(recording, replacing: target)
        #expect(try Data(contentsOf: target) == Data(contentsOf: recording.fileURL))
    }

    @Test func dragFileIsATemplateNamedCopy() throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let recording = try VideoCardFixture.recording(in: dir.url.appending(path: "src"))
        let url = try RecordingFileExport.writeDragFile(for: recording, template: .default, in: dir.url.appending(path: "drag"))
        #expect(url.lastPathComponent.hasPrefix("HakoShot "))
        #expect(url.pathExtension == "mp4")
        #expect(try Data(contentsOf: url) == Data(contentsOf: recording.fileURL))
    }
}

@Suite("ClipboardWriter file URL")
struct ClipboardWriterFileURLTests {
    @Test func writeFilePutsTheFileURLOnThePasteboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hakanyucel.hakoshot.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let recording = try VideoCardFixture.recording(in: dir.url)

        // Stale image data must be cleared.
        try ClipboardWriter(pasteboard: pasteboard).write(PostCaptureFixture.image())
        #expect(ClipboardWriter(pasteboard: pasteboard).writeFile(url: recording.fileURL))

        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        #expect(urls?.map(\.standardizedFileURL) == [recording.fileURL.standardizedFileURL])
        #expect(pasteboard.string(forType: .fileURL).flatMap(URL.init(string:))?.standardizedFileURL == recording.fileURL.standardizedFileURL)
        #expect(pasteboard.data(forType: .png) == nil)
    }
}

@Suite("QuickAccessController video", .serialized)
struct QuickAccessControllerVideoTests {
    private final class Harness {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let exportDir = PostCaptureFixture.ScratchDirectory()
        let sourceDir = PostCaptureFixture.ScratchDirectory()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.hakanyucel.hakoshot.tests.\(UUID().uuidString)"))
        let controller: QuickAccessController

        init() {
            scratchSettings.settings.set(exportDir.url.path, for: .outputSaveFolderPath)
            scratchSettings.settings.set(false, for: .quickAccessAutoCloseEnabled)
            controller = QuickAccessController(
                settings: scratchSettings.settings,
                clipboardWriter: ClipboardWriter(pasteboard: pasteboard),
                animates: false
            )
        }

        func recording(format: RecordingFormat = .video, historyID: UUID? = nil) throws -> RecordingResult {
            try VideoCardFixture.recording(format: format, in: sourceDir.url, historyID: historyID)
        }

        func exportedFiles() -> [URL] {
            (try? FileManager.default.contentsOfDirectory(at: exportDir.url, includingPropertiesForKeys: nil)) ?? []
        }

        func cleanup() {
            controller.closeAll()
            pasteboard.releaseGlobally()
            scratchSettings.cleanup()
            exportDir.cleanup()
            sourceDir.cleanup()
        }
    }

    @Test func saveCopiesToExportLocationAsMP4() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        var events: [QuickAccessHistoryEvent] = []
        var saved: URL?
        var closedURL: URL?
        var imageClosed = 0
        harness.controller.onHistoryEvent = { events.append($0) }
        harness.controller.onRecordingSaved = { _, url in saved = url }
        harness.controller.onRecordingClosed = { _, url in closedURL = url }
        harness.controller.onClosed = { _, _ in imageClosed += 1 }

        let historyID = UUID()
        let recording = try harness.recording(historyID: historyID)
        let id = harness.controller.show(recording: recording)
        #expect(harness.controller.visibleItems.count == 1)
        #expect(harness.controller.visibleResults.isEmpty)

        harness.controller.perform(.save, on: id)

        let files = harness.exportedFiles()
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.pathExtension == "mp4")
        #expect(file.lastPathComponent.hasPrefix("HakoShot "))
        #expect(try Data(contentsOf: file) == Data(contentsOf: recording.fileURL))
        #expect(saved?.standardizedFileURL == file.standardizedFileURL)
        #expect(closedURL == saved)
        #expect(imageClosed == 0)
        #expect(harness.controller.visibleCount == 0)
        // historyID defaults to the recording's.
        #expect(events.first == .saved(historyID: historyID, url: try #require(saved)))
        #expect(events.last == .closed(historyID: historyID))
    }

    @Test func gifSavesWithGIFExtension() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        let id = harness.controller.show(recording: try harness.recording(format: .gif))
        harness.controller.perform(.save, on: id)
        #expect(harness.exportedFiles().map(\.pathExtension) == ["gif"])
    }

    @Test func copyWritesTheFileURL() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        let recording = try harness.recording()
        let savedURL = harness.exportDir.url.appending(path: "already saved.mp4")
        let id = harness.controller.show(recording: recording, savedURL: savedURL)
        harness.controller.perform(.copy(keepOpen: true), on: id)

        let urls = harness.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]
        #expect(urls?.map(\.standardizedFileURL) == [savedURL.standardizedFileURL])
        #expect(harness.pasteboard.data(forType: .png) == nil)
        #expect(harness.controller.visibleCount == 1)
    }

    @Test func copyUnsavedCardUsesAnExistingFile() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        let recording = try harness.recording()
        let id = harness.controller.show(recording: recording)
        harness.controller.perform(.copy(keepOpen: true), on: id)
        let url = try #require((harness.pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first)
        // Either the template-named drag link (if ready) or the recording itself.
        #expect(url.pathExtension == "mp4")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(harness.exportedFiles().isEmpty)   // copy never saves
    }

    @Test func pinIsIgnoredAndR3ActionsNeedHooks() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        var pinned = 0
        harness.controller.onPin = { _ in pinned += 1 }
        let id = harness.controller.show(recording: try harness.recording())
        harness.controller.perform(.pin, on: id)
        harness.controller.perform(.edit, on: id)          // no video editor yet → stays
        harness.controller.perform(.convertToGIF, on: id)  // no GIF export yet → stays
        #expect(pinned == 0)
        #expect(harness.controller.visibleCount == 1)

        var edited: [QuickAccessRecordingRequest] = []
        var converted = 0
        harness.controller.onEditRecording = { edited.append($0) }
        harness.controller.onConvertToGIF = { _ in converted += 1 }
        harness.controller.perform(.convertToGIF, on: id)
        #expect(converted == 1)
        #expect(harness.controller.visibleCount == 1)      // GIF arrives as its own card
        harness.controller.perform(.edit, on: id)
        #expect(edited.count == 1)
        #expect(harness.controller.visibleCount == 0)
    }

    @Test func restoreBringsBackTheVideoCard() throws {
        let harness = Harness()
        defer { harness.cleanup() }
        let recording = try harness.recording()
        harness.controller.show(recording: recording)
        harness.controller.show(PostCaptureFixture.captureResult())
        // closeAll closes newest first, so the video (oldest) is the last closed.
        harness.controller.closeAll()
        #expect(harness.controller.restoreLastClosed())
        #expect(harness.controller.visibleItems.last?.recording?.fileURL == recording.fileURL)
        #expect(harness.controller.visibleResults.isEmpty)
        #expect(harness.controller.restoreLastClosed())
        #expect(harness.controller.visibleResults.count == 1)
    }

    @Test func debugSampleIsATwoSecondMP4() async throws {
        let dir = PostCaptureFixture.ScratchDirectory()
        defer { dir.cleanup() }
        let result = try await QuickAccessVideoDebug.makeSampleResult(
            seconds: 2,
            pixelSize: CGSize(width: 320, height: 180),
            in: dir.url
        )
        #expect(result.fileURL.pathExtension == "mp4")
        let asset = AVURLAsset(url: result.fileURL)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        #expect(tracks.count == 1)
        let size = try await tracks[0].load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))
        #expect(result.thumbnail.width == 320)
    }
}
