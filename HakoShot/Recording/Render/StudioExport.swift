import AVFoundation
import CoreImage
import Foundation
import HakoKit
import os

/// A Studio composition ready to play, sample or export, plus the adapter
/// that draws its frames.
nonisolated struct StudioRenderBuild: @unchecked Sendable {
    let composition: RenderComposition
    let adapter: StudioRenderAdapter
    let sourceInfo: RenderSourceInfo
}

/// Builds Studio compositions and runs Studio exports (plan §4.19, R6.4).
///
/// The composition holds the kept segments of the screen video (trim +
/// cuts, back to back), the camera video with the same edit (shifted by
/// `cameraTimeOffset`) and the audio tracks; its video composition runs
/// `StudioCompositor` with a `StudioRenderAdapter`. The same build serves
/// the editor preview (`AVPlayerItem`), frame PNGs (`AVAssetImageGenerator`)
/// and export (`ReencodeJob` for MP4, `GIFExportJob` for GIF).
nonisolated enum StudioExport {
    enum Purpose: Sendable, Equatable {
        /// Editor preview at `outputHeight` (≤ the project's), preview blur.
        case preview(outputHeight: Int, fps: Int)
        /// MP4 export / exact frames: the project's canvas and fps.
        case video
        /// GIF export: the canvas scaled to `project.export.gif`, no audio.
        case gif
    }

    /// Preview frame rate cap (the player only shows what the display can).
    static let previewMaxFPS = 60

    // MARK: Build

    /// Builds the composition for `project` (packaged at `media.packageURL`).
    ///
    /// - Parameters:
    ///   - includeAudio: `false` for frame sampling.
    ///   - cursorPath: the editor's cached path (else built from `media`).
    ///   - blur: motion blur quality; default `.preview` for the preview,
    ///     `.standard` otherwise.
    @concurrent
    static func build(
        project: StudioProject,
        media: StudioMediaContext,
        purpose: Purpose,
        includeAudio: Bool = true,
        cursorPath: CursorPath? = nil,
        blur: MotionBlurPlan.Parameters? = nil,
        renderer: StudioFrameRenderer? = nil
    ) async throws -> StudioRenderBuild {
        let asset = AVURLAsset(url: media.media.screen)
        let info = try await RenderPipeline.probe(asset)
        let timeline = project.timeline
        guard timeline.outputDuration > 0 else { throw RenderError.emptyTimeline }

        // Size, frame rate, blur quality.
        let exportFPS = project.export.outputFPS(sourceFPS: project.source.fps)
        let adapter: StudioRenderAdapter
        let fps: Int
        switch purpose {
        case .preview(let height, let previewFPS):
            fps = max(1, min(previewFPS, Self.previewMaxFPS))
            adapter = StudioRenderAdapter(project: project, media: media, cursorPath: cursorPath,
                                          outputHeight: min(height, project.canvas.outputHeight),
                                          fps: fps, blur: blur ?? .preview, renderer: renderer)
        case .video:
            fps = exportFPS
            adapter = StudioRenderAdapter(project: project, media: media, cursorPath: cursorPath,
                                          fps: fps, blur: blur ?? .standard, renderer: renderer)
        case .gif:
            let options = project.export.gif.normalized()
            let canvas = project.canvasPixelSize
            let size = options.outputSize(sourceWidth: Int(canvas.width), sourceHeight: Int(canvas.height))
            fps = max(1, min(options.fps, GIFExportOptions.maxFPS))
            adapter = StudioRenderAdapter(project: project, media: media, cursorPath: cursorPath,
                                          outputHeight: size.height, fps: fps, blur: blur ?? .standard, renderer: renderer)
        }
        let renderSize = adapter.canvasSize

        let composition = AVMutableComposition()
        guard let screenSource = try await asset.loadTracks(withMediaType: .video).first,
              let screenTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.noVideoTrack }
        try await insert(timeline, of: screenSource, into: screenTrack)

        // Camera (Studio recordings with a webcam).
        var cameraTrackID: CMPersistentTrackID?
        if project.source.hasCamera, project.camera.visible, let cameraURL = media.media.camera,
           FileManager.default.fileExists(atPath: cameraURL.path),
           let cameraSource = try? await AVURLAsset(url: cameraURL).loadTracks(withMediaType: .video).first,
           let cameraTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try await insert(timeline, of: cameraSource, into: cameraTrack, offset: media.metadata?.cameraTimeOffset ?? 0)
            cameraTrackID = cameraTrack.trackID
        }

        // Audio.
        var audioTracks: [AVMutableCompositionTrack] = []
        if includeAudio, purpose != .gif, !project.audio.muted {
            for source in try await asset.loadTracks(withMediaType: .audio) {
                guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try await insert(timeline, of: source, into: track)
                audioTracks.append(track)
            }
        }

        let videoComposition = VideoCompositionBuilder.makeVideoComposition(
            renderer: adapter,
            screenTrackID: screenTrack.trackID,
            cameraTrackID: cameraTrackID,
            duration: composition.duration,
            renderSize: renderSize,
            fps: fps,
            timeline: timeline
        )
        let mix = VideoCompositionBuilder.audioMix(for: audioTracks, audio: project.audio)
        let render = RenderComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: mix.mix,
            videoTrack: screenTrack,
            audioTracks: audioTracks,
            renderSize: renderSize,
            fps: fps,
            timeline: timeline,
            postGain: mix.postGain
        )
        return StudioRenderBuild(composition: render, adapter: adapter, sourceInfo: info)
    }

    // MARK: Export

    /// Exports `project` to `destination` as MP4 (canvas size, export fps /
    /// quality / codec, audio mix) or GIF (`project.export.format`), with
    /// the pipeline's partial-file, progress and cancellation rules.
    @concurrent
    static func export(
        project: StudioProject,
        media: StudioMediaContext,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let started = ContinuousClock.now
        let project = project.normalized()
        let isGIF = project.export.format == .gif
        let build = try await build(project: project, media: media, purpose: isGIF ? .gif : .video)
        let output = RenderOutput(destination: destination)
        let reporter = RenderProgress(progress)
        try output.prepare()
        let plan = isGIF ? nil : Self.plan(project: project, build: build)
        do {
            try Task.checkCancellation()
            if let plan {
                let job = try ReencodeJob(composition: build.composition, plan: plan, url: output.partial, progress: reporter)
                try await job.run()
            } else {
                try await GIFExportJob.run(composition: build.composition, options: project.export.gif.normalized(),
                                           to: output.partial, progress: reporter)
            }
            try Task.checkCancellation()
            try output.commit()
        } catch {
            output.discard()
            if error is CancellationError || Task.isCancelled {
                Log.studio.notice("studio export cancelled")
                throw CancellationError()
            }
            Log.studio.error("studio export failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        reporter.report(1)
        let elapsed = ContinuousClock.now - started
        let size = build.composition.renderSize
        Log.studio.notice("exported \(destination.lastPathComponent, privacy: .public) [\(isGIF ? "gif" : "mp4", privacy: .public) \(Int(size.width))x\(Int(size.height))@\(build.composition.fps), \(String(format: "%.2f", build.composition.duration), privacy: .public) s] in \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))), privacy: .public)")
        return destination
    }

    /// MP4 encoder plan: canvas size, export fps, quality bitrate, H.264
    /// switching to HEVC above its size limit, AAC stereo / mono.
    static func plan(project: StudioProject, build: StudioRenderBuild) -> RenderPlan {
        let width = Int(build.composition.renderSize.width), height = Int(build.composition.renderSize.height)
        var codec = project.export.codec
        if codec == .h264, !RecordingGeometry.fitsH264(width: width, height: height) { codec = .hevc }
        let fps = build.composition.fps
        let includesAudio = !project.audio.muted && !build.composition.audioTracks.isEmpty
        let channels = project.audio.mono ? 1 : min(2, max(1, build.sourceInfo.audioChannelCounts.max() ?? 2))
        return RenderPlan(
            mode: .reencode, width: width, height: height, fps: fps, codec: codec,
            bitrate: project.export.quality.bitrate(width: width, height: height, fps: fps, codec: codec),
            includesAudio: includesAudio, audioChannels: includesAudio ? channels : 0
        )
    }

    // MARK: Frames

    /// The exact composited frame at timeline time `outputTime` (export
    /// quality, motion blur included). `outputHeight`: render smaller.
    @concurrent
    static func frameImage(
        project: StudioProject,
        media: StudioMediaContext,
        outputTime: Double,
        outputHeight: Int? = nil
    ) async throws -> CGImage {
        let purpose: Purpose = if let outputHeight {
            .preview(outputHeight: outputHeight, fps: project.export.outputFPS(sourceFPS: project.source.fps))
        } else {
            .video
        }
        let build = try await build(project: project, media: media, purpose: purpose, includeAudio: false, blur: .standard)
        let generator = AVAssetImageGenerator(asset: build.composition.composition)
        generator.videoComposition = build.composition.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frame = 1 / Double(max(build.composition.fps, 1))
        let t = min(max(outputTime, 0), max(build.composition.duration - frame, 0))
        do {
            return try await generator.image(at: VideoCompositionBuilder.cmTime(t)).image
        } catch {
            throw RenderError.cannotRead("frame at \(t) s: \(error.localizedDescription)")
        }
    }

    // MARK: Private

    /// Inserts the kept segments of `timeline` back to back; `offset` shifts
    /// the source ranges (camera clock). Missing media is skipped, so tracks
    /// stay in sync.
    private static func insert(_ timeline: EditTimeline, of source: AVAssetTrack, into track: AVMutableCompositionTrack, offset: Double = 0) async throws {
        let available = try await source.load(.timeRange)
        var cursor = CMTime.zero
        for segment in timeline.segments {
            let range = CMTimeRange(start: VideoCompositionBuilder.cmTime(segment.start + offset),
                                    end: VideoCompositionBuilder.cmTime(segment.end + offset))
            let clamped = range.intersection(available)
            if !clamped.isEmpty, clamped.duration.seconds > 0 {
                try track.insertTimeRange(clamped, of: source, at: cursor + (clamped.start - range.start))
            }
            cursor = cursor + range.duration
        }
    }
}
