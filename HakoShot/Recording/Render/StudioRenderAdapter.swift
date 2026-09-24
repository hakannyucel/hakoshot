import AVFoundation
import CoreImage
import Foundation
import HakoKit
import ImageIO
import os

extension Log {
    nonisolated static let studio = Logger(subsystem: subsystem, category: "studio")
}

/// The edit-independent inputs of a `.hakostudio` package, loaded once per
/// open editor / export: media locations, `events.json`, the raw cursor
/// track, the recorded cursor shapes and the background image assets.
nonisolated struct StudioMediaContext: @unchecked Sendable {
    // `CGImage` (sprites, assets) is immutable and thread-safe.
    let packageURL: URL
    let media: StudioProjectFile.MediaURLs
    let metadata: RecordingMetadata?
    /// `cursor.bin`, time sorted by `CursorPath`; empty when absent.
    let cursorSamples: [CursorSample]
    /// Recorded cursor shapes by `RecordingMetadata.cursorShapes` index.
    let cursorSprites: [Int: StudioCursorSprite]
    let assets: [AssetID: CGImage]

    init(
        packageURL: URL,
        media: StudioProjectFile.MediaURLs,
        metadata: RecordingMetadata?,
        cursorSamples: [CursorSample],
        cursorSprites: [Int: StudioCursorSprite],
        assets: [AssetID: CGImage]
    ) {
        self.packageURL = packageURL
        self.media = media
        self.metadata = metadata
        self.cursorSamples = cursorSamples
        self.cursorSprites = cursorSprites
        self.assets = assets
    }

    /// Reads everything but the videos from the package at `packageURL`.
    static func load(packageURL: URL, project: StudioProject, assets: [AssetID: CGImage] = [:]) -> StudioMediaContext {
        let media = StudioProjectFile.mediaURLs(for: project, in: packageURL)
        let metadata = StudioProjectFile.readMetadata(for: project, in: packageURL)
        let samples = project.source.cursorBakedIn ? [] : StudioProjectFile.readCursorTrack(for: project, in: packageURL)
        var sprites: [Int: StudioCursorSprite] = [:]
        if let metadata, let folder = media.cursorsDirectory {
            for (index, shape) in metadata.cursorShapes.enumerated() {
                let url = folder.appendingPathComponent("\(shape.hash).png")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
                sprites[index] = StudioCursorSprite(image: image, shape: shape)
            }
        }
        return StudioMediaContext(
            packageURL: packageURL, media: media, metadata: metadata,
            cursorSamples: samples, cursorSprites: sprites, assets: assets
        )
    }

    /// Smoothed cursor path for `smoothing`; `nil` without a cursor track
    /// (classic recordings, cursor baked in).
    func cursorPath(smoothing: Double) -> CursorPath? {
        guard !cursorSamples.isEmpty else { return nil }
        return CursorPath(samples: cursorSamples, clicks: metadata?.clicks ?? [], smoothing: smoothing)
    }
}

/// `StudioFrameRendering` for Studio projects (plan §4.19, R6.4): wraps
/// HakoKit's `StudioFrameRenderer` with an immutable project snapshot and
/// the paths precomputed once per edit (`CameraPath`, `CursorPath`), the
/// recorded cursor sprites and a `MotionBlurPlan` per frame.
///
/// One adapter serves preview (`.preview` blur: ≤ 2 samples, canvas scaled
/// to the view), thumbnails / frame PNGs and export (`.standard` blur, the
/// project's canvas). The canvas is rendered natively at `canvasSize` (the
/// project with its `outputHeight` replaced), so preview frames cost less
/// and lengths (padding, corners, shadow) scale with the height.
nonisolated struct StudioRenderAdapter: StudioFrameRendering {
    /// Project used for layout (its `canvas.outputHeight` may be the
    /// preview / GIF height instead of the export height).
    let project: StudioProject
    let metadata: RecordingMetadata?
    let cursorPath: CursorPath?
    let cameraPath: CameraPath
    let renderer: StudioFrameRenderer
    let sprites: [Int: StudioCursorSprite]
    /// `metadata.keys` merged into badge runs for `project.keystrokes`'s
    /// filter (once per edit, not per frame).
    let keystrokes: StudioKeystrokeEntries
    let blur: MotionBlurPlan.Parameters
    /// Output frame rate (motion blur shutter length).
    let fps: Double

    var usesColorManagement: Bool { true }
    /// The composition is tagged BT.709 (like the recordings), which Apple's
    /// decoders display with a 1.961 gamma; frames are encoded for that, so
    /// the exported video shows the sRGB colors the renderer drew (the
    /// background matches the screenshot tool's).
    var outputColorSpace: CGColorSpace? { StudioColor.videoOutput }

    /// Render size in pixels (even).
    var canvasSize: CGSize { project.canvasPixelSize }

    /// - Parameters:
    ///   - outputHeight: canvas height to render at; `nil` = the project's.
    ///   - cursorPath: pass the editor's cached path; `nil` builds one from
    ///     `media` (or none without a cursor track).
    ///   - renderer: share one between adapters to keep its background cache.
    init(
        project: StudioProject,
        media: StudioMediaContext,
        cursorPath: CursorPath? = nil,
        outputHeight: Int? = nil,
        fps: Int? = nil,
        blur: MotionBlurPlan.Parameters = .standard,
        renderer: StudioFrameRenderer? = nil
    ) {
        var p = project
        if let outputHeight { p.canvas.outputHeight = RecordingGeometry.evenFloor(Double(max(outputHeight, 2))) }
        self.project = p
        self.metadata = media.metadata
        let path = cursorPath ?? media.cursorPath(smoothing: project.cursor.smoothing)
        self.cursorPath = path
        self.cameraPath = CameraPath(project: project, metadata: media.metadata, cursorPath: path)
        let assets = media.assets
        self.renderer = renderer ?? StudioFrameRenderer(backgroundImages: { assets[$0] })
        self.sprites = media.cursorSprites
        self.keystrokes = project.keystrokes.visible
            ? StudioKeystrokeEntries(metadata: media.metadata, filter: project.keystrokes.displayFilter)
            : .empty
        self.blur = blur
        self.fps = Double(fps ?? project.export.outputFPS(sourceFPS: project.source.fps))
    }

    /// Layout and overlay state at `sourceTime` (zoom from the `CameraPath`).
    func state(sourceTime: Double, outputTime: Double?) -> StudioFrameState {
        StudioFrameState.make(project: project, metadata: metadata, cursorPath: cursorPath,
                              sourceTime: sourceTime, outputTime: outputTime, viewport: cameraPath,
                              keystrokes: keystrokes)
    }

    /// Motion blur samples for timeline time `outputTime`.
    func blurPlan(outputTime: Double) -> MotionBlurPlan {
        MotionBlurPlan.make(project: project, metadata: metadata, cursorPath: cursorPath, viewport: cameraPath,
                            outputTime: outputTime, fps: fps, parameters: blur)
    }

    func renderFrame(_ context: StudioFrameContext) -> CIImage {
        let started = StudioRenderStats.now()
        defer { StudioRenderStats.shared.record(since: started) }
        let screen = Self.normalized(context.screen, to: project.source.pixelSize)
        let camera = context.camera
        let seconds = context.compositionTime.seconds
        let outputTime = seconds.isFinite ? seconds : 0
        let sprite: (Int) -> StudioCursorSprite? = { [sprites, project] index in
            project.cursor.style == .arrow ? nil : sprites[index]
        }
        let plan = project.motionBlur.enabled ? blurPlan(outputTime: outputTime) : .single(sourceTime: context.sourceTime)
        if plan.isBlurred {
            return renderer.renderBlurred(plan: plan, camera: camera, cursorSprite: sprite) { t in
                (screen, state(sourceTime: t, outputTime: outputTime))
            }
        }
        return renderer.render(source: screen, camera: camera,
                               state: state(sourceTime: context.sourceTime, outputTime: outputTime),
                               cursorSprite: sprite)
    }

    /// Renders one frame for a still `screen` image (tests, snapshots).
    func render(screen: CIImage, camera: CIImage? = nil, outputTime: Double) -> CIImage {
        let sourceTime = project.timeline.sourceTime(forOutput: outputTime)
        let context = StudioFrameContext(
            screen: screen, camera: camera,
            compositionTime: CMTime(seconds: outputTime, preferredTimescale: VideoCompositionBuilder.timescale),
            sourceTime: sourceTime, renderSize: canvasSize
        )
        return renderFrame(context).cropped(to: CGRect(origin: .zero, size: canvasSize))
    }

    /// The source frame at the origin with the project's pixel size (a
    /// classic mp4 whose encoded size differs from the project is scaled).
    static func normalized(_ image: CIImage, to size: CGSize) -> CIImage {
        let e = image.extent
        guard size.width > 0, size.height > 0, !e.isEmpty, !e.isInfinite else { return image }
        if e.origin == .zero, abs(e.width - size.width) < 0.5, abs(e.height - size.height) < 0.5 { return image }
        let t = CGAffineTransform(translationX: -e.minX, y: -e.minY)
            .concatenating(CGAffineTransform(scaleX: size.width / e.width, y: size.height / e.height))
        return image.transformed(by: t)
    }
}

/// Color spaces of the Studio render path.
nonisolated enum StudioColor {
    /// BT.709 primaries (= sRGB), D65, pure 1.961 gamma: how AVFoundation /
    /// ColorSync display BT.709-tagged video.
    static let videoOutput: CGColorSpace? = {
        let white: [CGFloat] = [0.95047, 1.0, 1.08883]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1.961, 1.961, 1.961]
        let matrix: [CGFloat] = [
            0.4124, 0.2126, 0.0193,
            0.3576, 0.7152, 0.1192,
            0.1805, 0.0722, 0.9505,
        ]
        return CGColorSpace(calibratedRGBWhitePoint: white, blackPoint: black, gamma: gamma, matrix: matrix)
    }()
}

/// Frame-building time of `StudioRenderAdapter.renderFrame` (Core Image
/// graph + motion blur plan; the GPU render happens later in the
/// compositor), plus a frames-per-second counter for the preview log.
nonisolated final class StudioRenderStats: Sendable {
    static let shared = StudioRenderStats()

    struct Snapshot: Sendable, Equatable {
        var frames = 0
        var totalSeconds = 0.0
        var averageMilliseconds: Double { frames > 0 ? totalSeconds / Double(frames) * 1000 : 0 }
    }

    private let state = OSAllocatedUnfairLock(initialState: Snapshot())

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func record(since start: UInt64) {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1e9
        state.withLock {
            $0.frames += 1
            $0.totalSeconds += elapsed
        }
    }

    /// Returns the counts since the last call and resets them.
    func take() -> Snapshot {
        state.withLock { current in
            defer { current = Snapshot() }
            return current
        }
    }
}
