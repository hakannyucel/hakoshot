import AppKit
import AVFoundation
import Foundation
import HakoKit
import Observation
import os

/// Inspector tabs (plan §4.19: Background | Cursor | Zoom | Camera | Keys | Audio;
/// Keys waits for the R7 keystroke badge, Motion blur has its own tab).
enum StudioInspectorTab: String, CaseIterable, Identifiable {
    case background, cursor, zoom, motionBlur, camera, keys, audio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .background: "Background"
        case .cursor: "Cursor"
        case .zoom: "Zoom"
        case .motionBlur: "Motion Blur"
        case .camera: "Camera"
        case .keys: "Keys"
        case .audio: "Audio"
        }
    }

    var symbol: String {
        switch self {
        case .background: "photo.on.rectangle"
        case .cursor: "cursorarrow"
        case .zoom: "plus.magnifyingglass"
        case .motionBlur: "wind"
        case .camera: "person.crop.square"
        case .keys: "keyboard"
        case .audio: "speaker.wave.2"
        }
    }
}

/// State and actions of one Studio editor window (plan §4.19, R6.4 / R7.2).
///
/// Every edit goes through `StudioStore` (HakoKit reducer + undo); after
/// each change the preview is rebuilt (debounced) and an autosave is
/// scheduled. ⌘S / closing writes the package atomically
/// (`StudioProjectFile.write`, media hard-linked) with a fresh preview.
@MainActor
@Observable
final class StudioViewModel {
    let store: StudioStore
    private(set) var packageURL: URL
    let playback = StudioPlayback()
    /// Edit-independent inputs (media, events, cursor track, sprites).
    private(set) var media: StudioMediaContext
    /// Background image assets by ID (added from the Background tab).
    private(set) var assets: [AssetID: CGImage]
    /// Source-time thumbnails for the video lane, evenly spaced.
    private(set) var thumbnails: [CGImage] = []
    var inspectorTab: StudioInspectorTab = .background
    /// Video-lane range selection in source seconds (Cut / ⌫ removes it).
    var rangeSelection: EditTimeRange?
    /// A cut the user clicked (⌫ restores it).
    var selectedCut: EditTimeRange?
    /// Transient status line ("Saved", errors).
    private(set) var statusMessage: String?
    private(set) var lastSaveDate: Date?

    /// Delay between the last edit and the autosave.
    @ObservationIgnored var autosaveDelay: Duration = .seconds(3)
    @ObservationIgnored private var autosaveTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var cursorPathCache: (smoothing: Double, path: CursorPath?)?

    static let log = Log.studio

    // MARK: Init

    init(packageURL: URL, contents: StudioProjectFile.Contents) {
        self.packageURL = packageURL
        self.store = StudioStore(project: contents.project)
        self.assets = contents.assets
        self.media = StudioMediaContext.load(packageURL: packageURL, project: contents.project, assets: contents.assets)
        playback.onNeedsRebuild = { [weak self] in self?.rebuildPreview(delay: .milliseconds(150)) }
    }

    /// Reads the package at `url`.
    static func load(url: URL) throws -> StudioViewModel {
        let contents = try StudioProjectFile.read(from: url)
        return StudioViewModel(packageURL: url, contents: contents)
    }

    /// Starts the preview and the thumbnail strip.
    func start() {
        rebuildPreview(delay: .zero)
        loadThumbnails()
    }

    func tearDown() {
        autosaveTask?.cancel()
        statusTask?.cancel()
        playback.tearDown()
    }

    // MARK: Read access

    var project: StudioProject { store.project }
    var metadata: RecordingMetadata? { media.metadata }
    var sourceDuration: Double { project.source.duration }
    var timeline: EditTimeline { project.timeline }
    var outputFPS: Int { project.export.outputFPS(sourceFPS: project.source.fps) }
    var hasUnsavedChanges: Bool { store.hasUnsavedChanges }
    var title: String { packageURL.deletingPathExtension().lastPathComponent }

    /// Playhead in source seconds.
    var playheadSourceTime: Double { timeline.sourceTime(forOutput: playback.currentTime) }

    /// Smoothed cursor path for the current smoothing (cached).
    func cursorPath() -> CursorPath? {
        let smoothing = project.cursor.smoothing
        if let cache = cursorPathCache, cache.smoothing == smoothing { return cache.path }
        let path = media.cursorPath(smoothing: smoothing)
        cursorPathCache = (smoothing, path)
        return path
    }

    // MARK: Editing

    func apply(_ action: StudioAction) {
        let before = store.project
        store.apply(action)
        if store.project != before { projectDidChange() }
    }

    /// Coalesces slider drags / timeline drags into one undo step.
    func beginInteraction(_ name: String) {
        store.beginInteraction(name)
    }

    func endInteraction() {
        store.endInteraction()
        scheduleAutosave()
    }

    func undo() {
        let before = store.project
        store.undo()
        if store.project != before { projectDidChange() }
    }

    func redo() {
        let before = store.project
        store.redo()
        if store.project != before { projectDidChange() }
    }

    private func projectDidChange() {
        if let cut = selectedCut, !project.edit.cuts.contains(cut) { selectedCut = nil }
        rebuildPreview(delay: .milliseconds(80))
        scheduleAutosave()
    }

    func rebuildPreview(delay: Duration) {
        playback.scheduleRebuild(project: project, media: media, cursorPath: cursorPath(), delay: delay)
    }

    // MARK: Timeline

    func seek(toSource t: Double) {
        let clamped = min(max(t, 0), sourceDuration)
        let output = timeline.outputTime(forSource: clamped) ?? nearestKeptOutputTime(forSource: clamped)
        playback.seek(toOutputNow: output)
    }

    /// Output time of the kept source time closest to `t` (inside a cut or
    /// outside the trim).
    func nearestKeptOutputTime(forSource t: Double) -> Double {
        let segments = timeline.segments
        guard let first = segments.first else { return 0 }
        var best = first.start, distance = abs(first.start - t)
        for segment in segments {
            for edge in [segment.start, segment.end] where abs(edge - t) < distance {
                best = edge
                distance = abs(edge - t)
            }
        }
        return timeline.outputTime(forSource: best) ?? timeline.outputTime(forSource: max(best - 1e-6, 0)) ?? 0
    }

    /// Current trim (full range when untrimmed).
    var trimRange: EditTimeRange {
        project.edit.trim ?? EditTimeRange(start: 0, end: sourceDuration)
    }

    /// Minimum kept length when trimming, seconds.
    static let minimumTrimLength = 0.2

    func setTrim(start: Double? = nil, end: Double? = nil) {
        var range = trimRange
        if let start { range.start = min(max(start, 0), range.end - Self.minimumTrimLength) }
        if let end { range.end = max(min(end, sourceDuration), range.start + Self.minimumTrimLength) }
        apply(.setTrim(range))
    }

    func cutSelection() {
        guard let range = rangeSelection, range.duration > 0.01 else { return }
        apply(.addCut(range))
        rangeSelection = nil
    }

    func restoreCut(_ cut: EditTimeRange) {
        apply(.removeCut(cut))
        if selectedCut == cut { selectedCut = nil }
    }

    /// ⌫: selected zoom, else selected cut (restored), else the range selection (cut).
    @discardableResult
    func deleteSelection() -> Bool {
        if let id = store.selectedZoomSegment {
            apply(.removeZoomSegment(id))
            return true
        }
        if let cut = selectedCut {
            restoreCut(cut)
            return true
        }
        if rangeSelection != nil {
            cutSelection()
            return true
        }
        return false
    }

    // MARK: Background assets

    /// Adds `image` as the background image asset and selects it.
    func setBackgroundImage(_ image: CGImage) {
        let id = AssetID()
        assets[id] = image
        media = StudioMediaContext(packageURL: media.packageURL, media: media.media, metadata: media.metadata,
                                   cursorSamples: media.cursorSamples, cursorSprites: media.cursorSprites, assets: assets)
        apply(.setBackgroundFill(.image(id)))
    }

    /// The image of the current `.image` fill, if any.
    var backgroundImageAsset: (AssetID, CGImage)? {
        guard case .image(let id) = project.canvas.background.fill, let image = assets[id] else { return nil }
        return (id, image)
    }

    // MARK: Saving

    /// Writes the package in place. `preview`: also refresh `preview.png`.
    @discardableResult
    func save(preview: Bool = true) async -> Bool {
        autosaveTask?.cancel()
        let project = store.project
        var previewImage: CGImage?
        if preview {
            let t = min(project.timeline.outputDuration * 0.1, 0.5)
            previewImage = try? await StudioExport.frameImage(
                project: project, media: media, outputTime: t,
                outputHeight: min(project.canvas.outputHeight, StudioProjectFile.previewMaxPixelSize)
            )
        }
        do {
            try StudioProjectFile.write(project, assets: assets, preview: previewImage, to: packageURL)
            store.markSaved()
            lastSaveDate = .now
            Self.log.notice("saved \(self.packageURL.lastPathComponent, privacy: .public)")
            return true
        } catch {
            Self.log.error("save failed: \(String(describing: error), privacy: .public)")
            showStatus("Couldn't save: \(error)")
            return false
        }
    }

    /// Saves in place (the ⌘S path) and reports it.
    func saveNow() {
        Task {
            if await save() { showStatus("Saved") }
        }
    }

    private func scheduleAutosave() {
        guard !store.isInteracting else { return }
        autosaveTask?.cancel()
        let delay = autosaveDelay
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.store.hasUnsavedChanges else { return }
            await self.save(preview: false)
        }
    }

    func showStatus(_ message: String) {
        statusMessage = message
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.statusMessage = nil
        }
    }

    // MARK: Thumbnails

    static let thumbnailCount = 24

    private func loadThumbnails() {
        let url = media.media.screen
        let duration = sourceDuration
        Task { [weak self] in
            let images = await Self.makeThumbnails(url: url, duration: duration, count: Self.thumbnailCount)
            self?.thumbnails = images
        }
    }

    @concurrent
    nonisolated static func makeThumbnails(url: URL, duration: Double, count: Int) async -> [CGImage] {
        guard duration > 0, count > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 320, height: 180)
        let tolerance = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [CGImage] = []
        for i in 0..<count {
            let t = (Double(i) + 0.5) / Double(count) * duration
            if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image {
                images.append(image)
            } else if let last = images.last {
                images.append(last)
            }
        }
        return images
    }
}
