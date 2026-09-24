import AVFoundation
import CoreImage
import Foundation
import HakoKit

/// An edit ready to play, thumbnail or export: the trimmed/cut
/// composition, its video composition (crop, scale, fps through
/// `StudioCompositor`) and its audio mix (per-track gains).
///
/// The same value serves `AVPlayerItem` preview (R3.3: set `asset`,
/// `videoComposition`, `audioMix`), `AVAssetImageGenerator` and
/// `RenderPipeline` export.
nonisolated struct RenderComposition: @unchecked Sendable {
    let composition: AVComposition
    /// Crop/scale/fps composition; always set when there is video.
    let videoComposition: AVVideoComposition?
    /// Per-track gains (≤ 1, see `postGain`); `nil` when unchanged or muted.
    let audioMix: AVAudioMix?
    let videoTrack: AVCompositionTrack?
    /// Composition audio tracks, in source track order (empty when muted).
    let audioTracks: [AVCompositionTrack]
    /// Output render size in pixels (even for MP4).
    let renderSize: CGSize
    let fps: Int
    let timeline: EditTimeline
    /// Extra gain applied to the mixed PCM (the part of `volume × trackGain`
    /// above 1 that `AVAudioMix` cannot express). 1 = none.
    let postGain: Double

    var duration: Double { timeline.outputDuration }
    var videoTrackID: CMPersistentTrackID? { videoTrack?.trackID }
    var audioTrackIDs: [CMPersistentTrackID] { audioTracks.map(\.trackID) }
}

/// Builds `RenderComposition`s from a `VideoEditRecipe` (plan §4.16, §4.19).
nonisolated enum VideoCompositionBuilder {
    enum Purpose: Sendable {
        /// MP4 export / preview: `recipe.outputSize`, `recipe.outputFPS`.
        case video
        /// GIF export: `recipe.gifOutputSize`, `recipe.gif.fps`, no audio.
        case gif
    }

    /// Time scale for composition edits (fine enough for 48 kHz audio and
    /// any frame rate).
    static let timescale: CMTimeScale = 48_000

    static func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: timescale)
    }

    /// Builds the composition for `recipe` over `asset` (probed as `info`).
    static func build(
        asset: AVAsset,
        info: RenderSourceInfo,
        recipe: VideoEditRecipe,
        purpose: Purpose = .video
    ) async throws -> RenderComposition {
        let recipe = recipe.normalized(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight, sourceDuration: info.duration)
        let timeline = recipe.timeline(sourceDuration: info.duration)
        guard timeline.outputDuration > 0 else { throw RenderError.emptyTimeline }

        let includeAudio = purpose == .video && !recipe.audio.muted
        let composition = AVMutableComposition()
        let videoSources = try await asset.loadTracks(withMediaType: .video)
        let audioSources = includeAudio ? try await asset.loadTracks(withMediaType: .audio) : []

        var videoTrack: AVMutableCompositionTrack?
        if let source = videoSources.first {
            videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            try await insert(timeline, of: source, into: videoTrack)
        }
        var audioTracks: [AVMutableCompositionTrack] = []
        for source in audioSources {
            guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try await insert(timeline, of: source, into: track)
            audioTracks.append(track)
        }

        let size: (width: Int, height: Int)
        let fps: Int
        switch purpose {
        case .video:
            size = recipe.outputSize(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight)
            fps = recipe.outputFPS(sourceFPS: info.fps)
        case .gif:
            size = recipe.gifOutputSize(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight)
            fps = min(recipe.gif.fps, GIFExportOptions.maxFPS)
        }
        let renderSize = CGSize(width: size.width, height: size.height)

        var videoComposition: AVVideoComposition?
        if let videoTrack {
            let crop = recipe.crop.map { _ in recipe.effectiveCrop(sourceWidth: info.pixelWidth, sourceHeight: info.pixelHeight) }
            videoComposition = makeVideoComposition(
                renderer: CropScaleFrameRenderer(crop: crop.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) }),
                screenTrackID: videoTrack.trackID,
                duration: composition.duration,
                renderSize: renderSize,
                fps: fps,
                timeline: timeline
            )
        }

        let mix = audioMix(for: audioTracks, audio: recipe.audio)
        return RenderComposition(
            composition: composition,
            videoComposition: videoComposition,
            audioMix: mix.mix,
            videoTrack: videoTrack,
            audioTracks: audioTracks,
            renderSize: renderSize,
            fps: fps,
            timeline: timeline,
            postGain: mix.postGain
        )
    }

    /// A one-instruction video composition driven by `StudioCompositor`.
    /// R6.4 calls this with its Studio renderer.
    static func makeVideoComposition(
        renderer: any StudioFrameRendering,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID? = nil,
        duration: CMTime,
        renderSize: CGSize,
        fps: Int,
        timeline: EditTimeline?
    ) -> AVVideoComposition {
        let instruction = StudioInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration),
            screenTrackID: screenTrackID,
            cameraTrackID: cameraTrackID,
            renderer: renderer,
            timeline: timeline
        )
        let configuration = AVVideoComposition.Configuration(
            colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
            colorTransferFunction: AVVideoTransferFunction_ITU_R_709_2,
            colorYCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
            customVideoCompositorClass: StudioCompositor.self,
            frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(1, fps))),
            instructions: [instruction],
            renderSize: renderSize
        )
        return AVVideoComposition(configuration: configuration)
    }

    /// Per-track volumes for `audio`. `AVAudioMix` volumes are kept in
    /// `0…1`: gains above 1 are divided by the largest gain, which is
    /// returned as `postGain` and applied to the mixed PCM by the pipeline.
    static func audioMix(for tracks: [AVCompositionTrack], audio: VideoEditAudio) -> (mix: AVAudioMix?, postGain: Double) {
        guard !tracks.isEmpty else { return (nil, 1) }
        let gains = tracks.indices.map { audio.gain(forTrack: $0) }
        let plan = mixPlan(gains: gains)
        guard plan.volumes.contains(where: { $0 != 1 }) else { return (nil, plan.postGain) }
        let mix = AVMutableAudioMix()
        mix.inputParameters = zip(tracks, plan.volumes).map { track, volume in
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(volume), at: .zero)
            return parameters
        }
        return (mix, plan.postGain)
    }

    /// Splits per-track gains (`0…2`) into mix volumes (`0…1`) and one
    /// post-mix gain: `gain[i] = volumes[i] × postGain`.
    static func mixPlan(gains: [Double]) -> (volumes: [Double], postGain: Double) {
        let peak = gains.max() ?? 1
        guard peak > 1 else { return (gains, 1) }
        return (gains.map { $0 / peak }, peak)
    }

    // MARK: Private

    private static func insert(_ timeline: EditTimeline, of source: AVAssetTrack, into track: AVMutableCompositionTrack?) async throws {
        guard let track else { throw RenderError.cannotRead("could not add a composition track") }
        // Audio can end a little before the video: insert only what exists,
        // at its output position, so the tracks stay in sync.
        let available = try await source.load(.timeRange)
        var cursor = CMTime.zero
        for segment in timeline.segments {
            let range = CMTimeRange(start: cmTime(segment.start), end: cmTime(segment.end))
            let clamped = range.intersection(available)
            if !clamped.isEmpty, clamped.duration.seconds > 0 {
                try track.insertTimeRange(clamped, of: source, at: cursor + (clamped.start - range.start))
            }
            cursor = cursor + range.duration
        }
    }
}
