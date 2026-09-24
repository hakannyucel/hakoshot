import AVFoundation
import AppKit
import HakoKit
import Observation
import os

extension Log {
    nonisolated static let videoEditor = Logger(subsystem: subsystem, category: "video-editor")
}

/// Resize presets of the classic editor (plan §4.16): the output's short
/// edge in pixels, aspect ratio kept. Presets larger than the (cropped)
/// source are hidden, so a preset never upscales.
nonisolated enum VideoResizePreset: String, CaseIterable, Identifiable, Sendable {
    case original, p2160, p1440, p1080, p720, p480

    var id: String { rawValue }

    var shortEdge: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }

    var label: String {
        switch self {
        case .original: "Original"
        case .p2160: "2160p (4K)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }

    /// `.original` plus every preset smaller than `cropShortEdge`.
    static func available(cropShortEdge: Int) -> [VideoResizePreset] {
        allCases.filter { preset in preset.shortEdge.map { $0 < cropShortEdge } ?? true }
    }
}

/// Progress of the running export (drives `VideoExportSheet`).
struct VideoExportState: Equatable {
    var title: String
    var progress: Double
}

/// One finished save, for `VideoEditorEvents.onSaved`.
struct VideoEditorSaveEvent {
    var sourceURL: URL
    var outputURL: URL
    var format: VideoEditOutputFormat
    /// Output length in seconds.
    var duration: Double
    var pixelSize: CGSize
    var historyID: UUID?
}

/// Integration hooks (set once by AppCoordinator; optional).
enum VideoEditorEvents {
    /// Called after every successful Save / Save As (not Copy).
    static var onSaved: ((VideoEditorSaveEvent) -> Void)?
}

/// State of one classic video editor window (kayit-teknik-plan §4.16):
/// the `VideoEditRecipe` with snapshot undo/redo, crop mode, playback of a
/// preview `AVPlayerItem` kept in sync with the recipe, and the save / copy
/// paths through `RenderPipeline`.
///
/// Times are **source** seconds: the preview plays the untrimmed source
/// (with crop / resize / fps / audio mix applied) and playback is bounded to
/// the trim range, so dragging a trim handle never rebuilds the preview.
@Observable
final class VideoEditorViewModel {
    enum LoadState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    /// What a finished export is used for.
    enum ExportOperation: Equatable {
        /// ⌘S / Done: the last save target, or a new file in the export folder.
        case save
        /// Save As / DEBUG apply: exactly this file.
        case saveAs(URL)
        /// Copy: a template-named temporary file whose URL goes on the pasteboard.
        case copy
    }

    static let undoLimit = 200
    /// `%mode` token for file names (plan §4.14: `Recording`).
    static let fileNameModeToken = "recording"

    let sourceURL: URL
    var historyID: UUID?
    @ObservationIgnored let settings: AppSettings
    @ObservationIgnored let asset: AVURLAsset
    @ObservationIgnored private let history: HistoryStore?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    private(set) var loadState: LoadState = .loading
    private(set) var info: RenderSourceInfo?

    // MARK: Recipe and undo

    private(set) var recipe: VideoEditRecipe
    /// Recipe the editor opened with (nothing to render when unchanged).
    private(set) var initialRecipe: VideoEditRecipe
    /// Recipe of the last save (baseline for "unsaved changes").
    private(set) var savedRecipe: VideoEditRecipe
    private(set) var undoStack: [VideoEditRecipe] = []
    private(set) var redoStack: [VideoEditRecipe] = []
    @ObservationIgnored private var interactionStart: VideoEditRecipe?

    // MARK: Crop mode

    private(set) var isCropping = false
    var cropAspect: CropAspect = .freeform
    @ObservationIgnored private var cropAtStart: VideoCropRect?

    // MARK: Playback

    /// Playhead in source seconds.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    /// Size of the preview frames (the output size, or the source while cropping).
    private(set) var previewRenderSize: CGSize = .zero
    /// Bumped each time a new preview item is installed.
    private(set) var previewGeneration = 0
    @ObservationIgnored private(set) var player: AVPlayer?
    @ObservationIgnored private var builtPreviewRecipe: VideoEditRecipe?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingSeek: Double?
    @ObservationIgnored private var seekInFlight = false
    @ObservationIgnored var isScrubbing = false

    // MARK: Save / export

    /// File ⌘S writes (set by the first save).
    private(set) var saveTarget: URL?
    private(set) var exportState: VideoExportState?
    private(set) var statusMessage: String?
    @ObservationIgnored private var exportTask: Task<URL?, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    /// Last export error, for DEBUG / tests.
    @ObservationIgnored private(set) var lastError: (any Error)?

    // MARK: Init

    /// Loads the source asynchronously (`load()`).
    init(sourceURL: URL, historyID: UUID? = nil, settings: AppSettings = .shared, history: HistoryStore? = .shared) {
        self.sourceURL = sourceURL
        self.historyID = historyID
        self.settings = settings
        self.history = history
        self.asset = AVURLAsset(url: sourceURL)
        let base = Self.initialRecipe(settings: settings, info: nil)
        recipe = base
        initialRecipe = base
        savedRecipe = base
    }

    /// A model for an already probed source (tests; no player until
    /// `startPlayback()`).
    convenience init(sourceURL: URL, info: RenderSourceInfo, historyID: UUID? = nil, settings: AppSettings = .shared, history: HistoryStore? = nil) {
        self.init(sourceURL: sourceURL, historyID: historyID, settings: settings, history: history)
        didLoad(info)
    }

    /// Probes the source; afterwards the recipe codec matches the source so
    /// trim-only edits pass through without re-encoding.
    func load() async {
        if let loadTask { return await loadTask.value }
        let task = Task { await self.performLoad() }
        loadTask = task
        await task.value
    }

    private func performLoad() async {
        guard info == nil else { return }
        do {
            let probed = try await RenderPipeline.probe(asset)
            guard probed.duration > 0 else { throw RenderError.emptyTimeline }
            didLoad(probed)
            Log.videoEditor.notice("opened \(self.sourceURL.lastPathComponent, privacy: .public): \(probed.pixelWidth)x\(probed.pixelHeight) \(String(format: "%.2f", probed.duration), privacy: .public) s @\(String(format: "%.1f", probed.fps), privacy: .public) fps, \(probed.audioTrackCount) audio")
        } catch {
            loadState = .failed(Self.describe(error))
            Log.videoEditor.error("cannot open \(self.sourceURL.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func didLoad(_ probed: RenderSourceInfo) {
        info = probed
        let base = Self.initialRecipe(settings: settings, info: probed)
        recipe = base
        initialRecipe = base
        savedRecipe = base
        previewRenderSize = CGSize(width: probed.pixelWidth, height: probed.pixelHeight)
        loadState = .ready
    }

    /// Defaults: quality and GIF options from the recording settings, codec
    /// from the source (`probe().codec`, so trim-only saves are passthrough).
    static func initialRecipe(settings: AppSettings, info: RenderSourceInfo?) -> VideoEditRecipe {
        var recipe = VideoEditRecipe()
        recipe.quality = VideoQuality(rawValue: settings.value(for: .recordingQuality).rawValue) ?? .default
        recipe.codec = info?.codec ?? VideoCodec(rawValue: settings.value(for: .recordingCodec).rawValue) ?? .h264
        recipe.gif = GIFExportOptions(
            fps: settings.value(for: .gifFrameRate),
            width: settings.value(for: .gifWidth),
            optimize: settings.value(for: .gifOptimize),
            quality: settings.value(for: .gifQuality)
        ).normalized()
        return recipe
    }

    // MARK: Source facts

    var sourceDuration: Double { info?.duration ?? 0 }
    /// Frame grid for snapping (the file's highest frame rate).
    var frameRate: Double { info.map { $0.fps > 0 ? $0.fps : 30 } ?? 30 }
    var frameDuration: Double { 1 / frameRate }
    var sourcePixelSize: CGSize { CGSize(width: info?.pixelWidth ?? 0, height: info?.pixelHeight ?? 0) }
    var audioTrackCount: Int { info?.audioTrackCount ?? 0 }

    /// The recipe clamped to the source (what an export renders).
    var normalizedRecipe: VideoEditRecipe {
        guard let info else { return recipe.normalized() }
        return recipe.normalized(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight, sourceDuration: info.duration)
    }

    var timeline: EditTimeline { recipe.timeline(sourceDuration: sourceDuration) }
    var trimRange: EditTimeRange { timeline.trim }
    var outputDuration: Double { timeline.outputDuration }

    var hasUnsavedChanges: Bool { normalized(recipe) != normalized(savedRecipe) }
    /// `true` when the recipe changes nothing (Done then just closes).
    var isUnchanged: Bool { normalized(recipe) == normalized(initialRecipe) }

    private func normalized(_ r: VideoEditRecipe) -> VideoEditRecipe {
        guard let info else { return r.normalized() }
        return r.normalized(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight, sourceDuration: info.duration)
    }

    // MARK: Editing and undo

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Applies `change` as one undo step (or as part of the open interaction).
    func edit(_ change: (inout VideoEditRecipe) -> Void) {
        var next = recipe
        change(&next)
        guard next != recipe else { return }
        if interactionStart == nil { pushUndo(recipe) }
        recipe = next
        recipeDidChange()
    }

    /// Starts a drag / slider interaction: every edit until
    /// `endInteraction()` becomes a single undo step.
    func beginInteraction() {
        if interactionStart == nil { interactionStart = recipe }
    }

    func endInteraction() {
        guard let start = interactionStart else { return }
        interactionStart = nil
        if start != recipe { pushUndo(start) }
    }

    func undo() {
        endInteraction()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        recipe = previous
        recipeDidChange()
    }

    func redo() {
        endInteraction()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        recipe = next
        recipeDidChange()
    }

    private func pushUndo(_ snapshot: VideoEditRecipe) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst(undoStack.count - Self.undoLimit) }
        redoStack.removeAll()
    }

    /// Replaces the recipe with `json` merged over it (DEBUG / automation):
    /// keys missing from `json` keep their current values.
    func applyRecipe(json: String) throws {
        let merged = try Self.merge(json: json, into: recipe)
        edit { $0 = merged }
    }

    /// `json` (a partial recipe) merged key by key over `base` (nested
    /// objects such as `audio` and `gif` merge too).
    static func merge(json: String, into base: VideoEditRecipe) throws -> VideoEditRecipe {
        guard let patch = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let current = try JSONSerialization.jsonObject(with: base.jsonData()) as? [String: Any]
        else { throw RenderError.cannotRead("recipe JSON must be an object") }
        let merged = deepMerge(current, patch)
        return try VideoEditRecipe.decode(json: JSONSerialization.data(withJSONObject: merged))
    }

    private static func deepMerge(_ base: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in patch {
            if let nested = value as? [String: Any], let existing = base[key] as? [String: Any] {
                out[key] = deepMerge(existing, nested)
            } else if value is NSNull {
                out.removeValue(forKey: key)
            } else {
                out[key] = value
            }
        }
        return out
    }

    private func recipeDidChange() {
        applyPlaybackBounds()
        player?.isMuted = recipe.audio.muted
        schedulePreviewRebuild()
    }

    // MARK: Trim

    /// Shortest kept range: `minimumTrimSeconds` rounded up to whole frames.
    var minimumTrimDuration: Double {
        let frames = (VideoEditorMetrics.minimumTrimSeconds * frameRate - 1e-9).rounded(.up)
        return min(max(1, frames) / frameRate, sourceDuration)
    }

    /// Moves the in point to the frame nearest `time`, keeping at least
    /// `minimumTrimDuration` before the out point.
    func setTrimStart(_ time: Double, scrub: Bool = true) {
        let end = trimRange.end
        var start = EditTimeline.snap(time, fps: frameRate)
        start = max(0, min(start, end - minimumTrimDuration))
        setTrim(start: start, end: end)
        if scrub { seek(to: start) }
    }

    /// Moves the out point to the frame nearest `time`, keeping at least
    /// `minimumTrimDuration` after the in point.
    func setTrimEnd(_ time: Double, scrub: Bool = true) {
        let start = trimRange.start
        var end = min(EditTimeline.snap(time, fps: frameRate), sourceDuration)
        end = min(sourceDuration, max(end, start + minimumTrimDuration))
        setTrim(start: start, end: end)
        if scrub { seek(to: max(start, end - frameDuration)) }
    }

    /// I: in point at the playhead.
    func setInPointAtPlayhead() { setTrimStart(currentTime, scrub: false) }
    /// O: out point at the playhead.
    func setOutPointAtPlayhead() { setTrimEnd(currentTime, scrub: false) }

    func resetTrim() { edit { $0.trim = nil; $0.cuts = [] } }

    private func setTrim(start: Double, end: Double) {
        let full = start <= 0 && end >= sourceDuration
        edit { $0.trim = full ? nil : EditTimeRange(start: start, end: end) }
    }

    // MARK: Crop

    /// Crop in source pixels (top-left origin); the whole frame when none.
    var cropRect: CGRect {
        let bounds = CGRect(origin: .zero, size: sourcePixelSize)
        guard let crop = recipe.crop else { return bounds }
        return CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height).intersection(bounds)
    }

    var cropBounds: CGRect { CGRect(origin: .zero, size: sourcePixelSize) }
    var hasCrop: Bool { recipe.crop != nil }

    func toggleCropMode() { setCropping(!isCropping) }

    func setCropping(_ on: Bool) {
        guard on != isCropping, info != nil else { return }
        endInteraction()
        if on { cropAtStart = recipe.crop }
        isCropping = on
        schedulePreviewRebuild(immediate: true)
    }

    /// Esc: leaves crop mode and restores the crop it started with.
    func cancelCropping() {
        guard isCropping else { return }
        let original = cropAtStart
        if recipe.crop != original { edit { $0.crop = original } }
        setCropping(false)
    }

    /// Sets the crop (source pixels); the whole frame clears it.
    func setCropRect(_ rect: CGRect) {
        let r = CropMath.rounded(rect).intersection(cropBounds)
        guard !r.isNull, r.width >= 1, r.height >= 1 else { return }
        let full = r == cropBounds
        edit {
            $0.crop = full ? nil : VideoCropRect(x: Int(r.minX), y: Int(r.minY), width: Int(r.width), height: Int(r.height))
        }
    }

    func setCropAspect(_ aspect: CropAspect) {
        cropAspect = aspect
        guard let ratio = aspect.value(original: sourcePixelSize) else { return }
        setCropRect(CropMath.fitted(ratio: ratio, in: cropRect))
    }

    /// W × H typed in the crop bar (aspect kept when one is chosen).
    func setCropSize(width: Int, height: Int) {
        setCropRect(CropMath.resized(cropRect, width: CGFloat(width), height: CGFloat(height), bounds: cropBounds))
    }

    func resetCrop() {
        cropAspect = .freeform
        edit { $0.crop = nil }
    }

    // MARK: Resize

    /// Size after crop (even), before resize.
    var croppedPixelSize: (width: Int, height: Int) {
        let crop = recipe.effectiveCrop(sourceWidth: max(2, Int(sourcePixelSize.width)), sourceHeight: max(2, Int(sourcePixelSize.height)))
        return (crop.width, crop.height)
    }

    /// Encoded size of the MP4 (or the GIF frame size for GIF output).
    var outputPixelSize: (width: Int, height: Int) {
        let w = max(2, Int(sourcePixelSize.width)), h = max(2, Int(sourcePixelSize.height))
        return recipe.format == .gif ? recipe.gifOutputSize(sourceWidth: w, sourceHeight: h) : recipe.outputSize(sourceWidth: w, sourceHeight: h)
    }

    var availableResizePresets: [VideoResizePreset] {
        let crop = croppedPixelSize
        return VideoResizePreset.available(cropShortEdge: min(crop.width, crop.height))
    }

    /// The preset matching the recipe, `nil` for a custom size.
    var resizePreset: VideoResizePreset? {
        if recipe.outputWidth == nil, recipe.outputHeight == nil, recipe.scale == nil { return .original }
        let crop = croppedPixelSize
        let landscape = crop.width >= crop.height
        for preset in VideoResizePreset.allCases {
            guard let edge = preset.shortEdge else { continue }
            if landscape, recipe.outputHeight == edge, recipe.outputWidth == nil { return preset }
            if !landscape, recipe.outputWidth == edge, recipe.outputHeight == nil { return preset }
        }
        return nil
    }

    func applyResizePreset(_ preset: VideoResizePreset) {
        let crop = croppedPixelSize
        edit { r in
            r.outputWidth = nil
            r.outputHeight = nil
            r.scale = nil
            guard let edge = preset.shortEdge else { return }
            if crop.width >= crop.height { r.outputHeight = edge } else { r.outputWidth = edge }
        }
    }

    /// Custom width; the height follows the crop aspect ratio.
    func setOutputWidth(_ width: Int) {
        guard width > 0 else { return }
        edit { r in
            r.outputWidth = width
            r.outputHeight = nil
            r.scale = nil
        }
    }

    /// Custom height; the width follows the crop aspect ratio.
    func setOutputHeight(_ height: Int) {
        guard height > 0 else { return }
        edit { r in
            r.outputWidth = nil
            r.outputHeight = height
            r.scale = nil
        }
    }

    // MARK: Quality, fps, codec, format

    /// "Original" (nil) plus the menu rates below the source rate.
    var availableFrameRates: [Int] {
        let source = Int(frameRate.rounded())
        return RecordingFrameRates.video.filter { $0 < source }
    }

    func setFPS(_ fps: Int?) { edit { $0.fps = fps } }
    func setQuality(_ quality: VideoQuality) { edit { $0.quality = quality } }
    func setCodec(_ codec: VideoCodec) { edit { $0.codec = codec } }
    func setFormat(_ format: VideoEditOutputFormat) { edit { $0.format = format } }
    func setGIFFPS(_ fps: Int) { edit { $0.gif.fps = fps } }
    func setGIFWidth(_ width: Int) { edit { $0.gif.width = width } }
    func setGIFQuality(_ quality: Double) { edit { $0.gif.quality = min(max(quality, 0), 1) } }
    func setGIFOptimize(_ on: Bool) { edit { $0.gif.optimize = on } }

    // MARK: Audio

    func setMuted(_ muted: Bool) { edit { $0.audio.muted = muted } }
    func setVolume(_ volume: Double) { edit { $0.audio.volume = min(max(volume, 0), VideoEditAudio.maxGain) } }
    func setMono(_ mono: Bool) { edit { $0.audio.mono = mono } }

    func trackGain(_ index: Int) -> Double {
        recipe.audio.trackGains.indices.contains(index) ? recipe.audio.trackGains[index] : 1
    }

    func setTrackGain(_ index: Int, _ gain: Double) {
        guard index >= 0 else { return }
        edit { r in
            while r.audio.trackGains.count <= index { r.audio.trackGains.append(1) }
            r.audio.trackGains[index] = min(max(gain, 0), VideoEditAudio.maxGain)
        }
    }

    // MARK: Status

    func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: VideoEditorMetrics.statusDuration)
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    static func describe(_ error: any Error) -> String {
        if let render = error as? RenderError { return render.description }
        return error.localizedDescription
    }

    // MARK: Teardown

    /// Stops playback and releases the player (window closed).
    func tearDown() {
        previewTask?.cancel()
        exportTask?.cancel()
        statusTask?.cancel()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
    }
}

// MARK: - Playback

extension VideoEditorViewModel {
    /// Creates the player and the first preview item.
    func startPlayback() {
        guard player == nil, info != nil else { return }
        let player = AVPlayer()
        player.actionAtItemEnd = .pause
        player.isMuted = recipe.audio.muted
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.playerTimeDidChange(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            let itemID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let itemID, itemID == self.player?.currentItem.map(ObjectIdentifier.init) else { return }
                self.isPlaying = false
            }
        }
        schedulePreviewRebuild(immediate: true)
    }

    /// What the preview shows: no trim (playback is bounded instead), the
    /// whole frame while cropping, the GIF size / fps for GIF output.
    var previewRecipe: VideoEditRecipe {
        var r = recipe
        r.trim = nil
        r.cuts = []
        if isCropping {
            r.crop = nil
            r.outputWidth = nil
            r.outputHeight = nil
            r.scale = nil
        } else if r.format == .gif, let info {
            let size = r.gifOutputSize(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight)
            r.outputWidth = size.width
            r.outputHeight = size.height
            r.scale = nil
            r.fps = r.gif.fps
        }
        r.format = .mp4
        r.audio.muted = false
        return normalized(r)
    }

    /// Plain source playback suffices (no crop, resize, fps or audio change).
    static func previewNeedsComposition(_ recipe: VideoEditRecipe, info: RenderSourceInfo) -> Bool {
        let size = recipe.outputSize(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight)
        return recipe.crop != nil
            || size.width != info.pixelWidth || size.height != info.pixelHeight
            || recipe.fps.map { $0 < Int(info.fps.rounded()) } ?? false
            || !recipe.audio.isUnchanged
    }

    func schedulePreviewRebuild(immediate: Bool = false) {
        guard player != nil else { return }
        previewTask?.cancel()
        previewTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(for: VideoEditorMetrics.previewDebounce) }
            guard !Task.isCancelled else { return }
            await self?.rebuildPreview()
        }
    }

    private func rebuildPreview() async {
        guard let info, let player else { return }
        let target = previewRecipe
        guard target != builtPreviewRecipe else { return }
        let item: AVPlayerItem
        var renderSize = CGSize(width: info.pixelWidth, height: info.pixelHeight)
        if Self.previewNeedsComposition(target, info: info) {
            do {
                let composition = try await VideoCompositionBuilder.build(asset: asset, info: info, recipe: target)
                guard !Task.isCancelled else { return }
                item = AVPlayerItem(asset: composition.composition)
                item.videoComposition = composition.videoComposition
                item.audioMix = composition.audioMix
                renderSize = composition.renderSize
            } catch {
                Log.videoEditor.error("preview build failed: \(String(describing: error), privacy: .public)")
                return
            }
        } else {
            item = AVPlayerItem(asset: asset)
        }
        guard !Task.isCancelled, self.player === player else { return }
        builtPreviewRecipe = target
        previewRenderSize = renderSize
        let wasPlaying = isPlaying
        player.replaceCurrentItem(with: item)
        applyPlaybackBounds()
        seek(to: currentTime)
        if wasPlaying { player.play() }
        previewGeneration += 1
    }

    private func applyPlaybackBounds() {
        guard let item = player?.currentItem else { return }
        let range = trimRange
        item.forwardPlaybackEndTime = VideoCompositionBuilder.cmTime(range.end)
        item.reversePlaybackEndTime = VideoCompositionBuilder.cmTime(range.start)
    }

    private func playerTimeDidChange(_ seconds: Double) {
        guard seconds.isFinite, !isScrubbing, !seekInFlight, pendingSeek == nil, isPlaying else { return }
        currentTime = min(max(seconds, 0), sourceDuration)
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Plays from the playhead (from the in point when outside the kept range).
    func play() {
        guard let player else { return }
        let range = trimRange
        if currentTime < range.start || currentTime >= range.end - frameDuration / 2 {
            seek(to: range.start)
        }
        applyPlaybackBounds()
        isPlaying = true
        player.play()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        if let time = player?.currentTime().seconds, time.isFinite, pendingSeek == nil, !seekInFlight {
            currentTime = min(max(time, 0), sourceDuration)
        }
    }

    /// ←/→: pause and move the playhead by `frames` frames on the frame grid.
    func step(frames: Int) {
        pause()
        let index = EditTimeline.frameIndex(at: currentTime, fps: frameRate) + frames
        seek(to: Double(index) / frameRate)
    }

    /// ⇧←/⇧→.
    func step(seconds: Double) {
        pause()
        seek(to: currentTime + seconds)
    }

    /// Moves the playhead (source seconds, clamped); consecutive calls
    /// coalesce so scrubbing chases the latest position.
    func seek(to time: Double) {
        let clamped = min(max(time.isFinite ? time : 0, 0), max(0, sourceDuration - frameDuration / 2))
        currentTime = clamped
        guard player != nil else { return }
        pendingSeek = clamped
        if !seekInFlight { performPendingSeek() }
    }

    private func performPendingSeek() {
        guard let player, let target = pendingSeek else {
            seekInFlight = false
            return
        }
        pendingSeek = nil
        seekInFlight = true
        player.seek(to: VideoCompositionBuilder.cmTime(target), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.performPendingSeek() }
        }
    }
}

// MARK: - Save, Save As, Copy

extension VideoEditorViewModel {
    var isExporting: Bool { exportTask != nil }

    /// Starts `operation` in a cancellable task (`cancelExport()`); the
    /// result is the written file or `nil` (failed / cancelled).
    @discardableResult
    func startExport(_ operation: ExportOperation) -> Task<URL?, Never> {
        if let exportTask { return exportTask }
        endInteraction()
        let task = Task { [weak self] () -> URL? in
            guard let self else { return nil }
            let url = await self.perform(operation)
            self.exportTask = nil
            return url
        }
        exportTask = task
        return task
    }

    func cancelExport() {
        exportTask?.cancel()
    }

    /// The Save / Save As / Copy path (UI and DEBUG apply).
    func perform(_ operation: ExportOperation) async -> URL? {
        guard info != nil else { return nil }
        let destination: URL
        switch operation {
        case .save: destination = saveDestination()
        case .saveAs(let url): destination = url
        case .copy: destination = copyDestination()
        }
        do {
            let url = try await render(to: destination, title: operation == .copy ? "Copying…" : "Saving…")
            switch operation {
            case .save, .saveAs:
                saveTarget = url
                savedRecipe = recipe
                await didSave(url)
                showStatus("Saved to \(url.deletingLastPathComponent().lastPathComponent)")
            case .copy:
                guard ClipboardWriter().writeFile(url: url) else { throw RenderError.cannotWrite("pasteboard") }
                showStatus("Copied to clipboard")
            }
            return url
        } catch {
            lastError = error
            if error is CancellationError {
                showStatus("Export cancelled")
            } else {
                showStatus("Something went wrong")
                NSSound.beep()
            }
            return nil
        }
    }

    /// Renders the normalized recipe to `destination` with progress in
    /// `exportState`. Throws `CancellationError` when the task is cancelled
    /// (no file is left behind, `RenderPipeline` removes its partial file).
    func render(to destination: URL, title: String = "Saving…") async throws -> URL {
        let recipe = normalizedRecipe
        exportState = VideoExportState(title: title, progress: 0)
        defer { exportState = nil }
        let started = ContinuousClock.now
        let url = try await RenderPipeline.shared.render(source: sourceURL, recipe: recipe, to: destination) { [weak self] value in
            Task { @MainActor in
                guard let self, var state = self.exportState else { return }
                state.progress = max(state.progress, value)
                self.exportState = state
            }
        }
        Log.videoEditor.notice("exported \(url.lastPathComponent, privacy: .public) in \(String(describing: ContinuousClock.now - started), privacy: .public)")
        return url
    }

    /// ⌘S target: the last save if the format still matches, else a new
    /// template-named file in the export folder (the original is never
    /// replaced, plan §4.16).
    func saveDestination() -> URL {
        if let saveTarget, saveTarget.pathExtension.lowercased() == recipe.format.fileExtension {
            return saveTarget
        }
        let folder = URL(fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath, isDirectory: true)
        let pattern = settings.value(for: .outputFileNameTemplate)
        let counter = FileNameCounter.take(pattern: pattern, settings: settings)
        return Self.newFileURL(in: folder, pattern: pattern, format: recipe.format, counter: counter)
    }

    /// Suggested Save As name.
    func suggestedFileName() -> String {
        if let saveTarget {
            return saveTarget.deletingPathExtension().lastPathComponent + "." + recipe.format.fileExtension
        }
        return namer(pattern: settings.value(for: .outputFileNameTemplate), format: recipe.format)
            .fileName(counter: FileNameCounter.peek(settings: settings), mode: Self.fileNameModeToken)
    }

    static func newFileURL(in folder: URL, pattern: String, format: VideoEditOutputFormat, counter: Int, date: Date = .now) -> URL {
        FileNamer(template: FileNameTemplate(pattern: pattern), pathExtension: format.fileExtension, clock: { date })
            .resolvedURL(in: folder, counter: counter, mode: fileNameModeToken)
    }

    private func namer(pattern: String, format: VideoEditOutputFormat) -> FileNamer {
        FileNamer(template: FileNameTemplate(pattern: pattern), pathExtension: format.fileExtension)
    }

    private func copyDestination() -> URL {
        let folder = DragSource.dragDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let name = namer(pattern: settings.value(for: .outputFileNameTemplate), format: recipe.format)
            .fileName(counter: FileNameCounter.peek(settings: settings), mode: Self.fileNameModeToken)
        return folder.appending(path: name)
    }

    /// History (`setSavedURL` on the entry the video came from) and the
    /// integration hook.
    private func didSave(_ url: URL) async {
        if let historyID, let history {
            await history.setSavedURL(url, for: historyID)
        }
        let size = outputPixelSize
        VideoEditorEvents.onSaved?(VideoEditorSaveEvent(
            sourceURL: sourceURL,
            outputURL: url,
            format: recipe.format,
            duration: outputDuration,
            pixelSize: CGSize(width: size.width, height: size.height),
            historyID: historyID
        ))
    }
}
