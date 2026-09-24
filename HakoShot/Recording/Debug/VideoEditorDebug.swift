#if DEBUG
import AVFoundation
import AppKit
import HakoKit
import os

/// DEBUG automation for the classic video editor (plan §7 R3.3):
///
/// - `hakoshot://debug-video-editor?filepath=<video>&snapshot=<png>` opens
///   the editor, waits for the preview and thumbnails, writes the window
///   content to `snapshot` and closes it (`keep=1` leaves it open). Extra
///   keys: `recipe=<json>` (partial recipe applied first), `t=<seconds>`
///   (playhead), `crop=1` (crop mode on).
/// - `hakoshot://debug-video-editor-apply?filepath=<video>&recipe=<json>&out=<file>`
///   runs the editor's save path without UI (`out` missing = ⌘S naming in
///   the export folder; `historyid=<uuid>` updates that History entry).
enum VideoEditorDebug {
    nonisolated enum ParseError: Error, Equatable {
        case missing(String)
    }

    nonisolated struct SnapshotParameters: Equatable, Sendable {
        var source: URL
        var snapshot: URL?
        var recipeJSON: String?
        var time: Double?
        var cropMode = false
        var keepOpen = false

        /// Keys: `filepath|path`, `snapshot`, `recipe`, `t`, `crop`, `keep`.
        init(queryItems: [URLQueryItem]) throws(ParseError) {
            let values = VideoEditorDebug.values(queryItems)
            guard let source = VideoEditorDebug.fileURL(values["filepath"] ?? values["path"]) else { throw .missing("filepath") }
            self.source = source
            snapshot = VideoEditorDebug.fileURL(values["snapshot"])
            recipeJSON = values["recipe"].flatMap { $0.isEmpty ? nil : $0 }
            time = values["t"].flatMap(Double.init)
            cropMode = VideoEditorDebug.flag(values["crop"])
            keepOpen = VideoEditorDebug.flag(values["keep"])
        }

        init(source: URL, snapshot: URL?, recipeJSON: String? = nil, time: Double? = nil, cropMode: Bool = false, keepOpen: Bool = false) {
            self.source = source
            self.snapshot = snapshot
            self.recipeJSON = recipeJSON
            self.time = time
            self.cropMode = cropMode
            self.keepOpen = keepOpen
        }
    }

    nonisolated struct ApplyParameters: Equatable, Sendable {
        var source: URL
        var recipeJSON: String?
        var out: URL?
        var historyID: UUID?

        /// Keys: `filepath|path`, `recipe`, `out`, `historyid`.
        init(queryItems: [URLQueryItem]) throws(ParseError) {
            let values = VideoEditorDebug.values(queryItems)
            guard let source = VideoEditorDebug.fileURL(values["filepath"] ?? values["path"]) else { throw .missing("filepath") }
            self.source = source
            recipeJSON = values["recipe"].flatMap { $0.isEmpty ? nil : $0 }
            out = VideoEditorDebug.fileURL(values["out"])
            historyID = values["historyid"].flatMap(UUID.init(uuidString:))
        }

        init(source: URL, recipeJSON: String?, out: URL?, historyID: UUID? = nil) {
            self.source = source
            self.recipeJSON = recipeJSON
            self.out = out
            self.historyID = historyID
        }
    }

    // MARK: debug-video-editor

    /// Opens the editor and writes its window (with the current video frame
    /// composited where the player layer is) to `snapshot`.
    @discardableResult
    static func openAndSnapshot(_ parameters: SnapshotParameters) async -> URL? {
        let controller = VideoEditorWindowController.open(url: parameters.source)
        await controller.load()
        let model = controller.model
        guard model.loadState == .ready else {
            Log.videoEditor.error("debug-video-editor: load failed")
            return nil
        }
        if let json = parameters.recipeJSON {
            do { try model.applyRecipe(json: json) } catch {
                Log.videoEditor.error("debug-video-editor: bad recipe \(json, privacy: .public)")
            }
        }
        if parameters.cropMode { model.setCropping(true) }
        model.seek(to: parameters.time ?? model.trimRange.start + model.timeline.trim.duration / 3)

        // Preview rebuilt for the final recipe, thumbnails loaded (≤ 8 s).
        let deadline = ContinuousClock.now + .seconds(8)
        try? await Task.sleep(for: VideoEditorMetrics.previewDebounce + .milliseconds(150))
        while ContinuousClock.now < deadline, !(controller.thumbnails.isComplete && model.previewGeneration > 0) {
            try? await Task.sleep(for: .milliseconds(100))
        }

        var written: URL?
        if let snapshot = parameters.snapshot, let data = await windowPNG(controller) {
            do {
                try FileManager.default.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: snapshot)
                written = snapshot
                Log.videoEditor.notice("debug-video-editor snapshot \(snapshot.path, privacy: .public)")
            } catch {
                Log.videoEditor.error("debug-video-editor: writing snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        if !parameters.keepOpen {
            VideoEditorWindowController.closeAllDiscardingChanges()
        }
        return written
    }

    /// In-process `cacheDisplay` of the window content. `AVPlayerLayer`
    /// does not render into it, so the preview frame at the playhead is
    /// placed in a temporary layer above the player layer first.
    static func windowPNG(_ controller: VideoEditorWindowController) async -> Data? {
        guard let content = controller.window?.contentView else { return nil }
        let model = controller.model
        let playerView = controller.playerView
        content.layoutSubtreeIfNeeded()

        let frameLayer = CALayer()
        if let frame = await previewFrame(model) {
            frameLayer.contents = frame
            frameLayer.contentsGravity = .resizeAspect
            frameLayer.frame = playerView.videoRect(for: model.isCropping ? model.sourcePixelSize : model.previewRenderSize)
            playerView.layer?.insertSublayer(frameLayer, above: playerView.playerLayer)
        }
        defer { frameLayer.removeFromSuperlayer() }
        content.displayIfNeeded()
        guard let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return nil }
        content.cacheDisplay(in: content.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// The preview frame at the playhead, rendered like the player item.
    private static func previewFrame(_ model: VideoEditorViewModel) async -> CGImage? {
        guard let info = model.info else { return nil }
        let recipe = model.previewRecipe
        let generator: AVAssetImageGenerator
        if VideoEditorViewModel.previewNeedsComposition(recipe, info: info) {
            guard let composition = try? await VideoCompositionBuilder.build(asset: model.asset, info: info, recipe: recipe) else { return nil }
            generator = AVAssetImageGenerator(asset: composition.composition)
            generator.videoComposition = composition.videoComposition
        } else {
            generator = AVAssetImageGenerator(asset: model.asset)
        }
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: VideoCompositionBuilder.cmTime(model.currentTime)).image
    }

    // MARK: debug-video-editor-apply

    /// The editor's save path without a window: load, merge `recipeJSON`
    /// over the editor's defaults (source codec, settings quality / GIF),
    /// render to `out` (or the ⌘S destination) and update History.
    static func apply(_ parameters: ApplyParameters, settings: AppSettings = .shared) async throws -> URL {
        let model = VideoEditorViewModel(
            sourceURL: parameters.source,
            historyID: parameters.historyID,
            settings: settings,
            history: parameters.historyID == nil ? nil : .shared
        )
        await model.load()
        if case .failed(let message) = model.loadState { throw RenderError.cannotRead(message) }
        if let json = parameters.recipeJSON { try model.applyRecipe(json: json) }
        let operation: VideoEditorViewModel.ExportOperation = parameters.out.map { .saveAs($0) } ?? .save
        guard let url = await model.perform(operation) else {
            throw model.lastError ?? RenderError.cannotWrite("export failed")
        }
        Log.videoEditor.notice("debug-video-editor-apply wrote \(url.path, privacy: .public)")
        return url
    }

    /// URL entry point: logs instead of throwing.
    static func runApply(_ parameters: ApplyParameters) async {
        do {
            _ = try await apply(parameters)
        } catch {
            Log.videoEditor.error("debug-video-editor-apply failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Helpers

    private nonisolated static func values(_ items: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items { if let value = item.value { values[item.name.lowercased()] = value } }
        return values
    }

    private nonisolated static func flag(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes"].contains(value.lowercased())
    }

    private nonisolated static func fileURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL { return url }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
#endif
