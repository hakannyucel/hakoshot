import AVFoundation
import CoreImage
import Foundation
import HakoKit

/// Everything a `StudioFrameRendering` needs to draw one output frame
/// (kayit-teknik-plan §4.19).
nonisolated struct StudioFrameContext {
    /// The screen track's frame for this time (BGRA, source pixels, Core
    /// Image bottom-left origin, extent `(0, 0, sourceWidth, sourceHeight)`).
    let screen: CIImage
    /// Optional camera track frame (R4/R6.4 Studio projects).
    let camera: CIImage?
    /// Time in the composition (= output time: the composition is built
    /// back to back from the kept segments).
    let compositionTime: CMTime
    /// Source media time of this frame (trim/cuts undone via the
    /// instruction's `EditTimeline`); equals the composition time when the
    /// instruction has no timeline. Studio state (zoom, cursor) is keyed by it.
    let sourceTime: Double
    /// Output size in pixels.
    let renderSize: CGSize
}

/// Per-frame drawing strategy hosted by `StudioCompositor`.
///
/// R3 ships `CropScaleFrameRenderer` (crop + scale, no background). R6.4
/// adds a Studio implementation that wraps `StudioFrameRenderer` with a
/// `StudioProject` snapshot and precomputed paths; the compositor, the
/// composition builder and the export pipeline stay unchanged.
nonisolated protocol StudioFrameRendering: Sendable {
    /// Returns the output frame. The result is cropped to
    /// `(0, 0, renderSize)` by the compositor.
    func renderFrame(_ context: StudioFrameContext) -> CIImage
    /// `true`: render through a color-managed context (sRGB output, e.g.
    /// `StudioFrameRenderer.sharedContext`); `false`: pass pixel values
    /// through untouched (crop/scale keeps the source colors bit for bit).
    var usesColorManagement: Bool { get }
    /// Color space the compositor renders into when `usesColorManagement`
    /// (R6.4 hook). Default sRGB.
    var outputColorSpace: CGColorSpace? { get }
}

nonisolated extension StudioFrameRendering {
    var usesColorManagement: Bool { false }
    var outputColorSpace: CGColorSpace? { CGColorSpace(name: CGColorSpace.sRGB) }
}

/// R3 renderer: crops the source to `crop` (source pixels, top-left
/// origin) and scales it to the render size. High-quality (Lanczos-like)
/// downsampling; edges are clamped so the border pixels stay opaque.
nonisolated struct CropScaleFrameRenderer: StudioFrameRendering, Hashable {
    /// Source-pixel crop, top-left origin; `nil` = full frame.
    var crop: CGRect?

    func renderFrame(_ context: StudioFrameContext) -> CIImage {
        Self.cropAndScale(context.screen, crop: crop, to: context.renderSize)
    }

    /// Crop (top-left pixel rect) + scale of `image` to exactly `size`.
    static func cropAndScale(_ image: CIImage, crop: CGRect?, to size: CGSize) -> CIImage {
        let extent = image.extent
        var rect = extent
        if let crop {
            // Top-left → Core Image bottom-left.
            rect = CGRect(x: extent.minX + crop.minX, y: extent.maxY - crop.maxY, width: crop.width, height: crop.height)
                .intersection(extent)
            if rect.isNull || rect.isEmpty { rect = extent }
        }
        let output = CGRect(origin: .zero, size: size)
        var result = image.cropped(to: rect).clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        let sx = size.width / rect.width, sy = size.height / rect.height
        if abs(sx - 1) > 1e-9 || abs(sy - 1) > 1e-9 {
            result = result.transformed(by: CGAffineTransform(scaleX: sx, y: sy), highQualityDownsample: true)
        }
        return result.cropped(to: output)
    }
}

/// The one instruction of a Studio/editor video composition
/// (`AVVideoCompositionInstructionProtocol`, plan §4.19). It spans the
/// whole composition and carries an immutable (hence `@unchecked
/// Sendable`) snapshot of the per-frame
/// state (`renderer`), so changing an edit means building a new video
/// composition (cheap) rather than mutating this object.
nonisolated final class StudioInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    /// Every frame may differ (zoom, cursor), so never reuse frames.
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceSampleDataTrackIDs: [NSNumber] = []

    /// Composition track with the screen video.
    let screenTrackID: CMPersistentTrackID
    /// Composition track with the camera video, if any (R6.4).
    let cameraTrackID: CMPersistentTrackID?
    let renderer: any StudioFrameRendering
    /// Maps composition (output) time back to source time; `nil` = identity.
    let timeline: EditTimeline?
    /// Fill used when a source frame is missing (should not happen).
    let backgroundColor: CIColor

    init(
        timeRange: CMTimeRange,
        screenTrackID: CMPersistentTrackID,
        cameraTrackID: CMPersistentTrackID? = nil,
        renderer: any StudioFrameRendering,
        timeline: EditTimeline? = nil,
        backgroundColor: CIColor = .black
    ) {
        self.timeRange = timeRange
        self.screenTrackID = screenTrackID
        self.cameraTrackID = cameraTrackID
        self.renderer = renderer
        self.timeline = timeline
        self.backgroundColor = backgroundColor
        var ids = [NSNumber(value: screenTrackID)]
        if let cameraTrackID { ids.append(NSNumber(value: cameraTrackID)) }
        self.requiredSourceTrackIDs = ids
        super.init()
    }

    /// Source media time for a composition time.
    func sourceTime(forComposition time: CMTime) -> Double {
        let t = time.seconds.isFinite ? time.seconds : 0
        return timeline?.sourceTime(forOutput: t) ?? t
    }
}
