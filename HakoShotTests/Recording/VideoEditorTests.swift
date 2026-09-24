import AVFoundation
import AppKit
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R3.3: classic video editor (kayit-teknik-plan §4.16, §7 R3.3).
@Suite("Video editor", .serialized)
struct VideoEditorTests {
    private static let info1080 = RenderSourceInfo(
        duration: 10, pixelWidth: 1920, pixelHeight: 1080, fps: 30, nominalFPS: 30, codec: .h264, audioChannelCounts: [2]
    )

    private static func settings() -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: "com.hakanyucel.hakoshot.tests.videoeditor.\(UUID().uuidString)")!)
    }

    private static func model(_ info: RenderSourceInfo = info1080) -> VideoEditorViewModel {
        VideoEditorViewModel(sourceURL: URL(fileURLWithPath: "/tmp/source.mp4"), info: info, settings: settings())
    }

    private static func isOnFrameGrid(_ time: Double, fps: Double) -> Bool {
        abs((time * fps).rounded() - time * fps) < 1e-9
    }

    // MARK: Thumbnail strip

    @Test func thumbnailCountFillsTheWidth() {
        let w = VideoEditorMetrics.thumbnailWidth
        #expect(w == Tokens.Recording.editorThumbnailWidth)
        #expect(ThumbnailStripLayout.count(forWidth: 10 * w) == 10)
        #expect(ThumbnailStripLayout.count(forWidth: 10 * w + 1) == 11)
        #expect(ThumbnailStripLayout.count(forWidth: w - 1) == 1)
        #expect(ThumbnailStripLayout.count(forWidth: 0) == 1)
        #expect(ThumbnailStripLayout.count(forWidth: 700) == Int((700 / w).rounded(.up)))
        // Every thumbnail covers its own slice; together they fill the strip.
        for width in stride(from: CGFloat(50), through: 1600, by: 37) {
            let count = ThumbnailStripLayout.count(forWidth: width)
            #expect(CGFloat(count) * w >= width)
            #expect(CGFloat(count - 1) * w < width)
        }
    }

    @Test func thumbnailTimesSitUnderTheirCenters() {
        let w = VideoEditorMetrics.thumbnailWidth
        let times = ThumbnailStripLayout.times(count: 3, width: 3 * w, duration: 3)
        #expect(times.count == 3)
        #expect(abs(times[0] - 0.5) < 1e-9 && abs(times[1] - 1.5) < 1e-9 && abs(times[2] - 2.5) < 1e-9)
        #expect(ThumbnailStripLayout.times(count: 0, width: 100, duration: 3).isEmpty)
    }

    // MARK: Trim

    @Test func trimHandlesSnapToFrames() {
        let model = Self.model()
        model.setTrimStart(1.013)
        #expect(model.trimRange.start == 1.0)
        model.setTrimEnd(7.49)
        #expect(abs(model.trimRange.end - 7.5) < 1e-9)
        for t in [0.017, 2.345, 3.3333, 4.9876] {
            model.setTrimStart(t)
            #expect(Self.isOnFrameGrid(model.trimRange.start, fps: 30))
        }
        // The playhead follows the dragged handle.
        #expect(model.currentTime == model.trimRange.start)

        // 60 fps grid.
        let fast = Self.model(RenderSourceInfo(duration: 5, pixelWidth: 1280, pixelHeight: 720, fps: 60, nominalFPS: 60, codec: .h264, audioChannelCounts: []))
        fast.setTrimEnd(3.007)
        #expect(Self.isOnFrameGrid(fast.trimRange.end, fps: 60))
        #expect(abs(fast.trimRange.end - 3.0) < 1e-9)
    }

    @Test func trimKeepsAMinimumLength() {
        let model = Self.model()
        #expect(abs(model.minimumTrimDuration - 0.1) < 1e-9) // 3 frames at 30 fps
        model.setTrimEnd(5)
        model.setTrimStart(9.99)
        #expect(abs(model.trimRange.start - 4.9) < 1e-9)
        model.setTrimEnd(0)
        #expect(abs(model.trimRange.end - 5.0) < 1e-9)
        #expect(model.trimRange.duration >= model.minimumTrimDuration - 1e-9)

        // Dragging back to the edges clears the trim.
        model.setTrimStart(-3)
        model.setTrimEnd(42)
        #expect(model.recipe.trim == nil)
        #expect(model.outputDuration == 10)
    }

    @Test func inAndOutPointsUseThePlayhead() {
        let model = Self.model()
        model.seek(to: 2.01)
        model.setInPointAtPlayhead()
        model.seek(to: 6.51)
        model.setOutPointAtPlayhead()
        #expect(model.trimRange.start == 2.0)
        #expect(abs(model.trimRange.end - 6.5) < 1e-9)
        model.step(frames: 3)
        #expect(abs(model.currentTime - (6.5 + 3.0 / 30)) < 1e-6)
    }

    @Test func timelineGeometryMapsTimeAndHandles() {
        let geometry = TimelineGeometry(width: 520, duration: 10, handleWidth: 10)
        #expect(geometry.trackWidth == 500)
        #expect(geometry.x(for: 0) == 10 && geometry.x(for: 10) == 510 && geometry.x(for: 5) == 260)
        #expect(geometry.time(for: 260) == 5)
        #expect(geometry.time(for: -40) == 0 && geometry.time(for: 900) == 10)
        let trim = EditTimeRange(start: 2, end: 8)
        #expect(geometry.dragTarget(at: geometry.x(for: 2) - 5, trim: trim) == .trimStart)
        #expect(geometry.dragTarget(at: geometry.x(for: 8) + 5, trim: trim) == .trimEnd)
        #expect(geometry.dragTarget(at: geometry.x(for: 5), trim: trim) == .playhead)
    }

    // MARK: Undo / redo

    @Test func undoRedoRestoresRecipes() {
        let model = Self.model()
        #expect(!model.canUndo && !model.canRedo)
        model.setMuted(true)
        model.setFPS(24)
        #expect(model.recipe.fps == 24 && model.recipe.audio.muted)

        model.undo()
        #expect(model.recipe.fps == nil && model.recipe.audio.muted)
        model.undo()
        #expect(!model.recipe.audio.muted)
        #expect(!model.canUndo && model.canRedo)
        #expect(!model.hasUnsavedChanges)

        model.redo()
        #expect(model.recipe.audio.muted && model.recipe.fps == nil)
        #expect(model.hasUnsavedChanges)

        // A new edit drops the redo history.
        model.setQuality(.low)
        #expect(!model.canRedo)

        // A drag / slider interaction is one undo step.
        let before = model.recipe
        model.beginInteraction()
        model.setVolume(0.4)
        model.setVolume(0.7)
        model.setVolume(1.6)
        model.endInteraction()
        #expect(model.recipe.audio.volume == 1.6)
        model.undo()
        #expect(model.recipe == before)
    }

    @Test func cancellingCropRestoresTheStartingCrop() {
        let model = Self.model()
        model.setCropRect(CGRect(x: 0, y: 0, width: 960, height: 540))
        model.setCropping(true)
        model.setCropRect(CGRect(x: 100, y: 100, width: 300, height: 300))
        model.cancelCropping()
        #expect(!model.isCropping)
        #expect(model.recipe.crop == VideoCropRect(x: 0, y: 0, width: 960, height: 540))
        model.resetCrop()
        #expect(model.recipe.crop == nil)
    }

    // MARK: Recipe JSON

    @Test func editsProduceTheExpectedRecipeJSON() throws {
        let model = Self.model()
        model.setTrimStart(2)
        model.setTrimEnd(7)
        model.setCropRect(CGRect(x: 0, y: 0, width: 1280, height: 720))
        #expect(model.availableResizePresets == [.original, .p480])
        model.applyResizePreset(.p480)
        #expect(model.resizePreset == .p480)
        model.setMuted(true)
        model.setFPS(30)
        #expect(model.outputPixelSize.width == 854 && model.outputPixelSize.height == 480)

        let actual = try JSONSerialization.jsonObject(with: model.recipe.jsonData()) as? NSDictionary
        let expected: NSDictionary = [
            "version": 1,
            "trim": ["start": 2, "end": 7],
            "cuts": [Any](),
            "crop": ["x": 0, "y": 0, "width": 1280, "height": 720],
            "outputHeight": 480,
            "fps": 30,
            "quality": "high",
            "codec": "h264",
            "audio": ["muted": true, "volume": 1, "mono": false, "trackGains": [Any]()],
            "format": "mp4",
            "gif": ["fps": 15, "width": 800, "optimize": true, "quality": 0.8],
        ]
        #expect(actual == expected)
    }

    @Test func recipeCodecFollowsTheSource() {
        let hevc = Self.model(RenderSourceInfo(duration: 4, pixelWidth: 1280, pixelHeight: 720, fps: 60, nominalFPS: 60, codec: .hevc, audioChannelCounts: []))
        #expect(hevc.recipe.codec == .hevc)
        // Trim only → passthrough, no re-encode.
        hevc.setTrimStart(1)
        let plan = RenderPlan.make(recipe: hevc.normalizedRecipe, source: hevc.info!)
        #expect(plan.mode == .passthrough)
    }

    @Test func partialRecipeJSONMergesOverTheCurrentRecipe() throws {
        let model = Self.model()
        model.setMuted(true)
        try model.applyRecipe(json: #"{"audio":{"volume":0.5},"trim":{"start":1,"end":2}}"#)
        #expect(model.recipe.audio.muted)
        #expect(model.recipe.audio.volume == 0.5)
        #expect(model.recipe.trim == EditTimeRange(start: 1, end: 2))
        #expect(model.recipe.codec == .h264)
        model.undo()
        #expect(model.recipe.trim == nil && model.recipe.audio.volume == 1)
    }

    @Test func keyMap() {
        let map = { (code: UInt16, chars: String, mods: NSEvent.ModifierFlags, crop: Bool) in
            VideoEditorKeyMap.command(keyCode: code, characters: chars, modifiers: mods, isCropping: crop)
        }
        #expect(map(49, " ", [], false) == .playPause)
        #expect(map(123, "", [], false) == .stepFrames(-1))
        #expect(map(124, "", [.shift], false) == .stepSeconds(1))
        #expect(map(34, "i", [], false) == .setInPoint)
        #expect(map(31, "o", [], false) == .setOutPoint)
        #expect(map(6, "z", [.command], false) == .undo)
        #expect(map(6, "z", [.command, .shift], false) == .redo)
        #expect(map(1, "s", [.command, .shift], false) == .saveAs)
        #expect(map(36, "\r", [], true) == .finishCrop)
        #expect(map(36, "\r", [], false) == nil)
        #expect(map(53, "", [], true) == .cancelCrop)
        #expect(VideoEditorTimeFormat.string(3.25) == "0:03.2")
        #expect(VideoEditorTimeFormat.string(42) == "0:42.0")
    }

    // MARK: Save path (debug-video-editor-apply)

    @Test func applySavePathProducesTheEditedFile() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "hako-video-editor-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.mp4")
        try await RenderTestMedia.write(to: source, width: 640, height: 360, fps: 30, seconds: 4, moving: true, audio: true)

        // Trim + crop (re-encode).
        let edited = directory.appending(path: "edited.mp4")
        let params = VideoEditorDebug.ApplyParameters(
            source: source,
            recipeJSON: #"{"trim":{"start":1,"end":3},"crop":{"x":0,"y":0,"width":320,"height":180}}"#,
            out: edited
        )
        let url = try await VideoEditorDebug.apply(params, settings: Self.settings())
        #expect(url == edited)
        let asset = AVURLAsset(url: edited)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2.0) <= 1.0 / 30 + 0.01)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 320, height: 180))
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)

        // Trim only + mute (passthrough, codec from the source).
        let trimmed = directory.appending(path: "trimmed.mp4")
        _ = try await VideoEditorDebug.apply(
            VideoEditorDebug.ApplyParameters(source: source, recipeJSON: #"{"trim":{"start":0.5,"end":2.5},"audio":{"muted":true}}"#, out: trimmed),
            settings: Self.settings()
        )
        let trimmedAsset = AVURLAsset(url: trimmed)
        #expect(abs(try await trimmedAsset.load(.duration).seconds - 2.0) <= 1.0 / 30 + 0.01)
        #expect(try await trimmedAsset.loadTracks(withMediaType: .audio).isEmpty)
        let trimmedSize = try await trimmedAsset.loadTracks(withMediaType: .video).first!.load(.naturalSize)
        #expect(trimmedSize == CGSize(width: 640, height: 360))
    }

    @Test func applyParametersParse() throws {
        let params = try VideoEditorDebug.ApplyParameters(queryItems: [
            URLQueryItem(name: "filepath", value: "/tmp/in.mov"),
            URLQueryItem(name: "recipe", value: #"{"trim":{"start":2,"end":7}}"#),
            URLQueryItem(name: "out", value: "/tmp/out.mp4"),
        ])
        #expect(params.source.path == "/tmp/in.mov" && params.out?.path == "/tmp/out.mp4")
        #expect(params.recipeJSON == #"{"trim":{"start":2,"end":7}}"#)
        let snapshot = try VideoEditorDebug.SnapshotParameters(queryItems: [
            URLQueryItem(name: "filepath", value: "/tmp/in.mov"),
            URLQueryItem(name: "snapshot", value: "/tmp/editor.png"),
            URLQueryItem(name: "crop", value: "1"),
        ])
        #expect(snapshot.snapshot?.path == "/tmp/editor.png" && snapshot.cropMode && !snapshot.keepOpen)
        #expect(throws: VideoEditorDebug.ParseError.missing("filepath")) {
            try VideoEditorDebug.ApplyParameters(queryItems: [])
        }
    }

    @Test func cancellingAnExportLeavesNoFile() async throws {
        let source = try await RenderTestMedia.source() // 10 s 1080p60
        let directory = FileManager.default.temporaryDirectory.appending(path: "hako-video-editor-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appending(path: "cancelled.mp4")

        let model = VideoEditorViewModel(sourceURL: source, settings: Self.settings(), history: nil)
        await model.load()
        #expect(model.loadState == .ready)
        model.setCropRect(CGRect(x: 0, y: 0, width: 1280, height: 720)) // forces a re-encode
        let task = model.startExport(.saveAs(destination))
        #expect(model.isExporting)
        // Let the render get going, then cancel.
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline, (model.exportState?.progress ?? 0) < 0.05 {
            try await Task.sleep(for: .milliseconds(20))
        }
        model.cancelExport()
        let result = await task.value
        #expect(result == nil)
        #expect(model.lastError is CancellationError)
        #expect(!model.isExporting && model.exportState == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(leftovers.isEmpty, "left: \(leftovers)")
        #expect(model.saveTarget == nil && model.hasUnsavedChanges)
    }
}
