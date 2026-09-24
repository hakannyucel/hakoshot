import AVFoundation
import Foundation
import HakoKit
import Observation
import os

/// The Studio preview player (plan §4.19): an `AVPlayer` over the Studio
/// composition, rebuilt (debounced) when the project changes.
///
/// - Only rendering changed (background, cursor, zoom, blur, camera look):
///   the current item keeps playing and gets a new `videoComposition`
///   (cheap; the paused frame redraws).
/// - Trim, cuts or audio changed: a new `AVPlayerItem`, at the same source
///   time when it is still kept.
///
/// Playing renders at the preview height with preview motion blur (≤ 2
/// samples); paused frames use export-quality blur.
@MainActor
@Observable
final class StudioPlayback {
    let player = AVPlayer()

    /// Timeline (output) time, seconds.
    private(set) var currentTime: Double = 0
    /// Output duration of the current item.
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    /// Last build error, if any (shown instead of the preview).
    private(set) var buildError: String?
    /// Canvas size the preview renders at.
    private(set) var renderSize: CGSize = .zero
    /// Preview canvas height cap: view height × backing scale (set by the view).
    var maxPreviewHeight = 1080 {
        didSet {
            guard abs(maxPreviewHeight - oldValue) > oldValue / 6 else { return }
            onNeedsRebuild?()
        }
    }

    /// Asked for a rebuild (preview size change); the view model reacts.
    @ObservationIgnored var onNeedsRebuild: (() -> Void)?

    @ObservationIgnored private var itemKey: ItemKey?
    @ObservationIgnored private var lastBuild: (project: StudioProject, media: StudioMediaContext, cursorPath: CursorPath?)?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private let renderer = StudioFrameRenderer(backgroundImages: { _ in nil })
    @ObservationIgnored private var statsTask: Task<Void, Never>?

    /// What forces a new player item.
    private struct ItemKey: Equatable {
        var edit: StudioEdit
        var muted: Bool
        var cameraVisible: Bool
    }

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = time.seconds
                if t.isFinite { self.currentTime = t }
                let playing = self.player.rate != 0
                if playing != self.isPlaying { self.isPlaying = playing }
            }
        }
    }

    func tearDown() {
        rebuildTask?.cancel()
        statsTask?.cancel()
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Build

    /// Rebuilds after `delay` (coalescing rapid edits, e.g. slider drags).
    func scheduleRebuild(project: StudioProject, media: StudioMediaContext, cursorPath: CursorPath?, delay: Duration = .milliseconds(80)) {
        lastBuild = (project, media, cursorPath)
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            await self.rebuild(project: project, media: media, cursorPath: cursorPath)
        }
    }

    /// Rebuilds with the last project (preview size or blur quality change).
    func rebuildLast() {
        guard let last = lastBuild else { return }
        scheduleRebuild(project: last.project, media: last.media, cursorPath: last.cursorPath, delay: .zero)
    }

    func rebuild(project: StudioProject, media: StudioMediaContext, cursorPath: CursorPath?) async {
        lastBuild = (project, media, cursorPath)
        generation += 1
        let token = generation
        let key = ItemKey(edit: project.edit, muted: project.audio.muted, cameraVisible: project.camera.visible)
        let height = min(project.canvas.outputHeight, max(maxPreviewHeight, 144))
        let fps = project.export.outputFPS(sourceFPS: project.source.fps)
        let blur: MotionBlurPlan.Parameters = isPlaying ? .preview : .standard
        do {
            let build = try await StudioExport.build(
                project: project, media: media, purpose: .preview(outputHeight: height, fps: fps),
                cursorPath: cursorPath, blur: blur, renderer: renderer
            )
            guard token == generation else { return }
            buildError = nil
            renderSize = build.composition.renderSize
            let composition = build.composition
            if key == itemKey, let item = player.currentItem, item.asset === composition.composition || canReuse(item, for: composition) {
                // Same tracks: swap only the rendering.
                item.videoComposition = composition.videoComposition
                item.audioMix = composition.audioMix
                if !isPlaying { refreshPausedFrame() }
                return
            }
            let sourceTime = lastSourceTime
            let item = AVPlayerItem(asset: composition.composition)
            item.videoComposition = composition.videoComposition
            item.audioMix = composition.audioMix
            itemKey = key
            currentItemComposition = composition.composition
            player.replaceCurrentItem(with: item)
            duration = composition.duration
            observeEnd(of: item)
            let resume = composition.timeline.outputTime(forSource: sourceTime) ?? 0
            await seek(toOutput: resume)
            timelineForSourceMapping = composition.timeline
        } catch is CancellationError {
            return
        } catch {
            guard token == generation else { return }
            buildError = String(describing: error)
            Log.studio.error("preview build failed: \(String(describing: error), privacy: .public)")
        }
    }

    @ObservationIgnored private var currentItemComposition: AVComposition?
    @ObservationIgnored private var timelineForSourceMapping: EditTimeline?

    private func canReuse(_ item: AVPlayerItem, for composition: RenderComposition) -> Bool {
        // A rebuilt AVMutableComposition is a new object; the item's own
        // composition has the same track layout when the key matched, but
        // its track IDs must match the new video composition's.
        guard let current = currentItemComposition else { return false }
        let old = current.tracks.map(\.trackID)
        let new = composition.composition.tracks.map(\.trackID)
        return old == new
    }

    /// Source time of the playhead in the current edit.
    private var lastSourceTime: Double {
        timelineForSourceMapping?.sourceTime(forOutput: currentTime) ?? currentTime
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didStopPlaying()
            }
        }
    }

    /// Forces the paused frame to redraw with the new video composition.
    private func refreshPausedFrame() {
        let time = player.currentTime()
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard player.currentItem != nil else { return }
        if currentTime >= duration - 0.05 {
            player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            currentTime = 0
        }
        isPlaying = true
        rebuildLast()     // preview-quality blur while playing
        player.play()
        startStats()
    }

    func pause() {
        player.pause()
        didStopPlaying()
    }

    private func didStopPlaying() {
        guard isPlaying else { return }
        isPlaying = false
        statsTask?.cancel()
        rebuildLast()     // export-quality blur for the paused frame
    }

    /// Seeks to timeline time `t` (clamped), frame exact.
    func seek(toOutput t: Double) async {
        let clamped = min(max(t, 0), max(duration, 0))
        currentTime = clamped
        await player.seek(to: VideoCompositionBuilder.cmTime(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toOutputNow t: Double) {
        let clamped = min(max(t, 0), max(duration, 0))
        currentTime = clamped
        player.seek(to: VideoCompositionBuilder.cmTime(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Steps by `frames` output frames (paused).
    func step(frames: Int, fps: Int) {
        pause()
        seek(toOutputNow: currentTime + Double(frames) / Double(max(fps, 1)))
    }

    /// `true` once the current item can show frames.
    var isReady: Bool { player.currentItem?.status == .readyToPlay }

    /// Waits (polling) until the item is ready or `timeout` passes.
    func waitUntilReady(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if isReady { return true }
            if buildError != nil { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return isReady
    }

    // MARK: Stats

    /// Logs composed frames per second and the average frame-building time
    /// every 2 s while playing (plan R6 acceptance: ≥ 30 fps at 1080p).
    private func startStats() {
        statsTask?.cancel()
        _ = StudioRenderStats.shared.take()
        statsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, self.isPlaying else { return }
                let stats = StudioRenderStats.shared.take()
                let size = self.renderSize
                Log.studio.notice("preview \(Int(size.width))x\(Int(size.height)): \(String(format: "%.1f", Double(stats.frames) / 2), privacy: .public) fps, build \(String(format: "%.2f", stats.averageMilliseconds), privacy: .public) ms/frame")
            }
        }
    }
}
