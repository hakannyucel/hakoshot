import CoreGraphics
import Foundation

/// Supplies the visible part of the source frame per time: the zoom / pan
/// hook. R7's `CameraPath` conforms; without one the full frame shows.
public protocol StudioViewport: Sendable {
    /// Visible source rect (source pixels, y down) at source time `t`. It
    /// should keep the source's aspect ratio and stay inside the frame.
    func viewRect(atSourceTime t: Double, sourceSize: CGSize) -> CGRect
}

/// No zoom: always the whole source frame.
public struct FullFrameViewport: StudioViewport {
    public init() {}

    public func viewRect(atSourceTime t: Double, sourceSize: CGSize) -> CGRect {
        CGRect(origin: .zero, size: sourceSize)
    }
}

/// Cursor draw parameters for one frame.
public struct StudioCursorState: Sendable, Hashable {
    /// Hot-spot position in canvas pixels (y down). May lie outside
    /// `contentRect` when zoomed; the renderer clips.
    public var position: CGPoint
    /// Hot-spot position in source pixels.
    public var sourcePosition: CGPoint
    /// Index into `RecordingMetadata.cursorShapes`.
    public var shapeIndex: Int
    /// Canvas pixels per cursor-image point (size multiplier × content
    /// scale × zoom).
    public var scale: Double
    /// `0…1` (hide-when-idle fade).
    public var opacity: Double
}

/// One active click ring.
public struct StudioClickEffectState: Sendable, Hashable {
    /// Center in canvas pixels.
    public var position: CGPoint
    /// `0…1` over `StudioFrameState.clickEffectDuration`.
    public var progress: Double
    /// Current ring radius in canvas pixels.
    public var radius: Double
    /// `0…1`.
    public var opacity: Double
    public var button: RecordingMouseButton
}

/// Webcam bubble placement for one frame.
public struct StudioCameraLayout: Sendable, Hashable {
    /// Canvas pixels.
    public var rect: CGRect
    public var shape: StudioCameraShape
    /// Canvas pixels (half the side for `.circle`).
    public var cornerRadius: Double
    public var mirrored: Bool
    /// `camera.mov` time to show.
    public var sourceTime: Double
    /// Drop shadow under the bubble, canvas pixels (`.none` = off).
    public var shadow: BackgroundShadow = .none
    /// White outline width, canvas pixels (0 = none).
    public var borderWidth: Double = 0
}

/// Everything needed to draw one output frame, computed purely from the
/// project, the recording metadata, the cursor path and a time (plan §4.19:
/// the compositor calls `make` per frame; preview and export share it).
///
/// All rects are canvas pixels, y down.
public struct StudioFrameState: Sendable, Hashable {
    /// Plan §5.2 click ring: 18 → 30 pt over 350 ms (reference points).
    /// The curve itself is `ClickEffectModel` (shared with the live overlay).
    public static let clickEffectDuration = ClickEffectModel.defaultDuration
    public static let clickStartRadius = ClickEffectModel.defaultStartRadius
    public static let clickEndRadius = ClickEffectModel.defaultEndRadius
    /// Hide-when-idle fade length, seconds.
    public static let idleFadeDuration = 0.3
    /// Webcam distance from the canvas edge, reference points.
    public static let cameraMargin = 24.0
    /// Squircle corner radius as a fraction of the side (matches `Tokens`).
    public static let cameraSquircleCornerFraction = 0.22
    public static let cameraRectangleCornerRadius = 12.0
    /// Live bubble shadow (`Tokens.Recording.cameraShadow` = floating card:
    /// 18 %, blur 24, 8 down), reference points.
    public static let cameraShadow = BackgroundShadow(opacity: 0.18, radius: 24, offsetX: 0, offsetY: 8)
    /// Optional white bubble outline, reference points.
    public static let cameraBorderWidth = 2.0

    /// Timeline (output) time.
    public var outputTime: Double
    /// Screen video time to show.
    public var sourceTime: Double
    public var canvasSize: CGSize
    /// Reference points → canvas pixels.
    public var lengthScale: Double
    public var background: BackgroundFill
    /// Where the screen content card is drawn.
    public var contentRect: CGRect
    /// Content card corner radius, canvas pixels.
    public var cornerRadius: Double
    /// Card shadow in canvas pixels.
    public var shadow: BackgroundShadow
    /// Visible source rect (source pixels); the full frame until R7 zoom.
    public var viewRect: CGRect
    /// `sourceSize.width / viewRect.width` (1 = no zoom).
    public var zoomScale: Double
    /// `nil` = no cursor drawn (baked in, hidden, off, no track).
    public var cursor: StudioCursorState?
    public var clickEffects: [StudioClickEffectState]
    /// `nil` = no webcam drawn.
    public var camera: StudioCameraLayout?
    /// `nil` = no keystroke badge on screen.
    public var keystrokeBadge: StudioKeystrokeBadgeState? = nil

    public var canvasRect: CGRect { CGRect(origin: .zero, size: canvasSize) }

    // MARK: Make

    /// State at timeline time `outputTime` (mapped through trim / cuts).
    public static func make(
        project: StudioProject,
        metadata: RecordingMetadata?,
        cursorPath: CursorPath?,
        outputTime: Double,
        viewport: any StudioViewport = FullFrameViewport(),
        keystrokes: StudioKeystrokeEntries? = nil
    ) -> StudioFrameState {
        let sourceTime = project.timeline.sourceTime(forOutput: outputTime)
        return make(project: project, metadata: metadata, cursorPath: cursorPath,
                    sourceTime: sourceTime, outputTime: outputTime, viewport: viewport, keystrokes: keystrokes)
    }

    /// State at source time `sourceTime` (`outputTime` defaults to its
    /// timeline position, or 0 when trimmed away).
    ///
    /// `keystrokes`: the merged key runs for `project.keystrokes` (build
    /// once with `StudioKeystrokeEntries(metadata:filter:)`); `nil` or a
    /// different filter merges `metadata.keys` here (slow per frame).
    public static func make(
        project: StudioProject,
        metadata: RecordingMetadata?,
        cursorPath: CursorPath?,
        sourceTime: Double,
        outputTime: Double? = nil,
        viewport: any StudioViewport = FullFrameViewport(),
        keystrokes: StudioKeystrokeEntries? = nil
    ) -> StudioFrameState {
        let source = project.source
        let sourceSize = source.pixelSize
        let canvasSize = project.canvasPixelSize
        let k = StudioCanvas.lengthScale(canvasHeight: canvasSize.height)
        let style = project.canvas.background
        let contentRect = contentRect(canvasSize: canvasSize, sourceSize: sourceSize,
                                      padding: max(style.padding, 0) * k, alignment: style.alignment)

        var view = viewport.viewRect(atSourceTime: sourceTime, sourceSize: sourceSize)
        if !(view.width > 0 && view.height > 0) || !view.origin.x.isFinite || !view.origin.y.isFinite {
            view = CGRect(origin: .zero, size: sourceSize)
        }
        let zoom = view.width > 0 ? sourceSize.width / view.width : 1
        /// Canvas px per source px.
        let contentScale = view.width > 0 ? contentRect.width / view.width : 1
        let pointsToPixels = metadata?.geometry.pixelsPerPoint ?? source.pixelsPerPoint
        func toCanvas(points p: CGPoint) -> CGPoint {
            let sx = p.x * pointsToPixels, sy = p.y * pointsToPixels
            return CGPoint(x: contentRect.minX + (sx - view.minX) * contentScale,
                           y: contentRect.minY + (sy - view.minY) * contentScale)
        }

        let editsCursor = !(metadata?.cursorBakedIn ?? false) && project.supportsCursorEditing
        let settings = project.cursor

        // Cursor.
        var cursorState: StudioCursorState?
        if editsCursor, settings.visible, let path = cursorPath, let sample = path.sample(at: sourceTime),
           !sample.flags.contains(.hidden) {
            var opacity = 1.0
            if settings.hideWhenIdle {
                let over = path.idleDuration(at: sourceTime) - settings.idleDelay
                if over > 0 { opacity = max(0, 1 - over / idleFadeDuration) }
            }
            if opacity > 0 {
                let point = CGPoint(x: Double(sample.x), y: Double(sample.y))
                cursorState = StudioCursorState(
                    position: toCanvas(points: point),
                    sourcePosition: CGPoint(x: point.x * pointsToPixels, y: point.y * pointsToPixels),
                    shapeIndex: Int(sample.shapeIndex),
                    scale: settings.scale * pointsToPixels * contentScale,
                    opacity: opacity
                )
            }
        }

        // Click effects.
        var effects: [StudioClickEffectState] = []
        if editsCursor, settings.clickEffect, let clicks = metadata?.clicks {
            let model = ClickEffectModel.standard
            for click in clicks where click.isDown {
                guard let frame = model.frame(at: sourceTime - click.time) else { continue }
                effects.append(StudioClickEffectState(
                    position: toCanvas(points: click.point),
                    progress: frame.progress,
                    radius: frame.radius * k,
                    opacity: frame.alpha,
                    button: click.button
                ))
            }
        }

        // Camera.
        var cameraLayout: StudioCameraLayout?
        if source.hasCamera, project.camera.visible {
            cameraLayout = cameraLayoutFor(project.camera, canvasSize: canvasSize, lengthScale: k,
                                           sourceTime: sourceTime + (metadata?.cameraTimeOffset ?? 0))
        }

        // Keystroke badge (source time, inside the content card).
        var badge: StudioKeystrokeBadgeState?
        let keySettings = project.keystrokes
        if keySettings.visible, let keys = metadata?.keys, !keys.isEmpty {
            let entries = keystrokes.flatMap { $0.filter == keySettings.displayFilter ? $0 : nil }
                ?? StudioKeystrokeEntries(metadata: metadata, filter: keySettings.displayFilter)
            badge = entries.badge(at: sourceTime, settings: keySettings, container: contentRect, lengthScale: k)
        }

        var shadow = style.shadow
        shadow.radius *= k
        shadow.offsetX *= k
        shadow.offsetY *= k

        return StudioFrameState(
            outputTime: outputTime ?? project.timeline.outputTime(forSource: sourceTime) ?? 0,
            sourceTime: sourceTime,
            canvasSize: canvasSize,
            lengthScale: k,
            background: style.fill,
            contentRect: contentRect,
            cornerRadius: max(style.cornerRadius, 0) * k,
            shadow: shadow,
            viewRect: view,
            zoomScale: zoom,
            cursor: cursorState,
            clickEffects: effects,
            camera: cameraLayout,
            keystrokeBadge: badge
        )
    }

    // MARK: Layout helpers

    /// The source aspect fitted into the canvas minus `padding` on every
    /// side, placed by `alignment`, snapped to whole pixels.
    public static func contentRect(canvasSize: CGSize, sourceSize: CGSize, padding: Double,
                                   alignment: BackgroundAlignment = .center) -> CGRect {
        let available = CGSize(width: max(canvasSize.width - 2 * padding, 1),
                               height: max(canvasSize.height - 2 * padding, 1))
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return CGRect(x: padding, y: padding, width: available.width, height: available.height)
        }
        let ratio = sourceSize.width / sourceSize.height
        var size = available
        if available.width / available.height > ratio {
            size.width = available.height * ratio
        } else {
            size.height = available.width / ratio
        }
        size = CGSize(width: max(size.width.rounded(), 1), height: max(size.height.rounded(), 1))
        let x = padding + ((available.width - size.width) * alignment.horizontal).rounded()
        let y = padding + ((available.height - size.height) * alignment.vertical).rounded()
        return CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    /// Webcam rect: shorter side = `size × min(canvas w, h)`, `cameraMargin`
    /// from the chosen corner.
    public static func cameraLayoutFor(_ camera: StudioCameraSettings, canvasSize: CGSize, lengthScale k: Double,
                                       sourceTime: Double) -> StudioCameraLayout {
        let side = (camera.size * min(canvasSize.width, canvasSize.height)).rounded()
        let aspect = camera.shape.aspect
        let size = aspect >= 1
            ? CGSize(width: (side * aspect).rounded(), height: side)
            : CGSize(width: side, height: (side / aspect).rounded())
        let margin = (cameraMargin * k).rounded()
        let x: Double
        let y: Double
        switch camera.corner {
        case .topLeft: (x, y) = (margin, margin)
        case .topRight: (x, y) = (canvasSize.width - margin - size.width, margin)
        case .bottomLeft: (x, y) = (margin, canvasSize.height - margin - size.height)
        case .bottomRight: (x, y) = (canvasSize.width - margin - size.width, canvasSize.height - margin - size.height)
        }
        let radius: Double = switch camera.shape {
        case .circle: min(size.width, size.height) / 2
        case .squircle: min(size.width, size.height) * cameraSquircleCornerFraction
        case .rectangle, .vertical: cameraRectangleCornerRadius * k
        }
        var shadow = BackgroundShadow.none
        if camera.shadow {
            shadow = cameraShadow
            shadow.radius *= k
            shadow.offsetX *= k
            shadow.offsetY *= k
        }
        return StudioCameraLayout(rect: CGRect(origin: CGPoint(x: x, y: y), size: size), shape: camera.shape,
                                  cornerRadius: radius, mirrored: camera.mirrored, sourceTime: sourceTime,
                                  shadow: shadow, borderWidth: camera.border ? max((cameraBorderWidth * k).rounded(), 1) : 0)
    }
}
