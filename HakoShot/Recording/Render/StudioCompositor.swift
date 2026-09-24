import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import HakoKit
import os

/// Custom video compositor for the editor and Studio (plan §4.19): one
/// code path for export (`AVAssetReaderVideoCompositionOutput`), preview
/// (`AVPlayerItem.videoComposition`) and thumbnails (`AVAssetImageGenerator`).
///
/// Frames arrive as BGRA, are wrapped in `CIImage`s and handed to the
/// instruction's `StudioFrameRendering`; the result is rendered into a
/// buffer from the render context on a serial queue. R3 uses the
/// crop/scale renderer (no background); R6.4 plugs in the Studio renderer
/// through `StudioInstruction` without changing this class.
nonisolated final class StudioCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    /// Pass-through context: no color management, so crop/scale keeps the
    /// source pixel values (the encoder tags the output BT.709 like the
    /// recording).
    static let passthroughContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .outputColorSpace: NSNull(),
        .cacheIntermediates: false,
        .name: "HakoShot.StudioCompositor",
    ])

    private static let pixelFormat = kCVPixelFormatType_32BGRA

    let sourcePixelBufferAttributes: [String: any Sendable]? = [
        kCVPixelBufferPixelFormatTypeKey as String: [StudioCompositor.pixelFormat],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [StudioCompositor.pixelFormat],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
        kCVPixelBufferMetalCompatibilityKey as String: true,
    ]

    private let queue = DispatchQueue(label: "com.hakanyucel.hakoshot.studio-compositor", qos: .userInitiated)
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var renderContext: AVVideoCompositionRenderContext?
        /// Bumped by `cancelAllPendingVideoCompositionRequests`; queued
        /// requests from an older generation finish as cancelled.
        var generation = 0
    }

    override init() {
        super.init()
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        state.withLock { $0.renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        let generation = state.withLock { $0.generation }
        queue.async { [self] in
            let (current, context) = state.withLock { ($0.generation, $0.renderContext) }
            guard current == generation else {
                request.finishCancelledRequest()
                return
            }
            autoreleasepool {
                do {
                    let frame = try render(request, renderContext: context ?? request.renderContext)
                    request.finish(withComposedVideoFrame: frame)
                } catch {
                    request.finish(with: error)
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        state.withLock { $0.generation &+= 1 }
    }

    // MARK: Rendering

    enum CompositorError: Error, CustomNSError {
        case wrongInstruction
        case noOutputBuffer

        static var errorDomain: String { "HakoShot.StudioCompositor" }
        var errorCode: Int {
            switch self {
            case .wrongInstruction: 1
            case .noOutputBuffer: 2
            }
        }
    }

    private func render(_ request: AVAsynchronousVideoCompositionRequest, renderContext: AVVideoCompositionRenderContext) throws -> CVPixelBuffer {
        guard let instruction = request.videoCompositionInstruction as? StudioInstruction else {
            throw CompositorError.wrongInstruction
        }
        guard let output = renderContext.newPixelBuffer() else { throw CompositorError.noOutputBuffer }
        let size = renderContext.size
        let bounds = CGRect(origin: .zero, size: size)

        let screenBuffer = request.sourceFrame(byTrackID: instruction.screenTrackID)
        let image: CIImage
        if let screenBuffer {
            let camera = instruction.cameraTrackID
                .flatMap { request.sourceFrame(byTrackID: $0) }
                .map { CIImage(cvPixelBuffer: $0) }
            let context = StudioFrameContext(
                screen: CIImage(cvPixelBuffer: screenBuffer),
                camera: camera,
                compositionTime: request.compositionTime,
                sourceTime: instruction.sourceTime(forComposition: request.compositionTime),
                renderSize: size
            )
            let background = CIImage(color: instruction.backgroundColor).cropped(to: bounds)
            image = instruction.renderer.renderFrame(context).cropped(to: bounds).composited(over: background)
            CVBufferPropagateAttachments(screenBuffer, output)
        } else {
            image = CIImage(color: instruction.backgroundColor).cropped(to: bounds)
        }

        if instruction.renderer.usesColorManagement {
            let space = instruction.renderer.outputColorSpace
            StudioFrameRenderer.sharedContext.render(image, to: output, bounds: bounds, colorSpace: space)
        } else {
            Self.passthroughContext.render(image, to: output, bounds: bounds, colorSpace: nil)
        }
        return output
    }
}
