@preconcurrency import AVFoundation
import AppKit
import HakoKit
import QuartzCore

/// The live webcam bubble (plan §4.8): a borderless, non-activating panel
/// inside the recorded rect showing the camera through the shape mask
/// (squircle / circle / 16:9 / 9:16), optionally mirrored, with a subtle
/// `Tokens.Recording.cameraShadow`.
///
/// - Drag moves it (never outside the recorded rect); on release it snaps to
///   the nearest corner (`CameraLayout.snapped`), reported via `onCornerChange`.
/// - Double-click toggles camera-fullscreen (fills the recorded rect).
/// - Classic recordings capture it INTO the video: show it before
///   `session.start` and pass `windowID` in `overlayWindowIDs`. Studio
///   recordings show it but do not except it (the camera goes to `camera.mov`).
///
/// Geometry is AppKit screen coordinates (y up); `show(recordedRect:)`
/// converts from Quartz `GlobalRect`.
@MainActor
final class WebcamBubbleWindow {
    let panel: WebcamBubblePanel
    let bubbleView: WebcamBubbleView

    private(set) var options: CameraOptions
    /// The recorded rect, AppKit screen coordinates.
    private(set) var recordedRect: CGRect = .zero
    /// The bubble (mask) rect, AppKit screen coordinates.
    private(set) var bubbleFrame: CGRect = .zero
    private(set) var corner: CameraCorner
    private(set) var isFullscreen = false
    private var dragStartFrame: CGRect?
    private var dragStartMouse: CGPoint = .zero

    /// Called after a drag snaps the bubble to a (possibly new) corner.
    var onCornerChange: ((CameraCorner) -> Void)?

    init(options: CameraOptions = CameraOptions()) {
        self.options = options
        corner = options.corner
        panel = WebcamBubblePanel()
        bubbleView = WebcamBubbleView(frame: .zero)
        panel.contentView = bubbleView
        bubbleView.owner = self
        applyAppearance()
    }

    /// `CGWindowID` while on screen (`nil` before the first `show`).
    var windowID: CGWindowID? {
        panel.windowNumber > 0 ? CGWindowID(panel.windowNumber) : nil
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Geometry

    var studioShape: StudioCameraShape { StudioCameraShape(rawValue: options.shape.rawValue) ?? .squircle }

    /// Transparent room around the bubble for its shadow.
    var shadowPadding: CGFloat {
        isFullscreen ? 0 : Tokens.Recording.cameraShadow.blur + Tokens.Recording.cameraShadow.y
    }

    /// Bubble size for the current options inside the recorded rect.
    var bubbleSize: CGSize {
        CameraLayout.bubbleSize(
            shortSide: Tokens.Recording.cameraSize(options.size),
            shape: studioShape,
            fitting: recordedRect.size,
            margin: Tokens.Recording.cameraMargin
        )
    }

    /// The corner frame for `corner` (AppKit coordinates).
    func cornerFrame(_ corner: CameraCorner) -> CGRect {
        CameraLayout.frame(
            size: bubbleSize,
            corner: StudioCameraCorner(rawValue: corner.rawValue) ?? .bottomRight,
            in: recordedRect,
            margin: Tokens.Recording.cameraMargin,
            yAxis: .up
        )
    }

    // MARK: Show / hide

    /// Shows the bubble in its corner of `recordedRect` (Quartz global
    /// points). Call BEFORE `session.start` (plan rule, `kayit-ilerleme.md`).
    @discardableResult
    func show(recordedRect: GlobalRect) -> Bool {
        let layout = DisplayLayoutProvider.currentLayout()
        guard let appKit = ScreenGeometry.appKitRect(fromGlobal: recordedRect, layout: layout) else { return false }
        show(appKitRecordedRect: appKit)
        return true
    }

    /// Shows the bubble in its corner of `rect` (AppKit screen coordinates).
    func show(appKitRecordedRect rect: CGRect) {
        recordedRect = rect.standardized
        bubbleFrame = isFullscreen ? recordedRect : cornerFrame(corner)
        applyFrame(animated: false)
        panel.orderFrontRegardless()
    }

    /// The recorded rect moved (window follower): keeps the corner (or
    /// fullscreen), re-fitting the bubble.
    func updateRecordedRect(_ rect: GlobalRect) {
        let layout = DisplayLayoutProvider.currentLayout()
        guard let appKit = ScreenGeometry.appKitRect(fromGlobal: rect, layout: layout) else { return }
        recordedRect = appKit.standardized
        guard dragStartFrame == nil else { return }
        bubbleFrame = isFullscreen ? recordedRect : cornerFrame(corner)
        applyFrame(animated: false)
    }

    func hide() {
        panel.orderOut(nil)
        dragStartFrame = nil
    }

    /// Shape / size / corner / mirror changed (HUD or settings).
    func setOptions(_ options: CameraOptions) {
        self.options = options
        corner = options.corner
        applyAppearance()
        guard recordedRect.width > 0 else { return }
        bubbleFrame = isFullscreen ? recordedRect : cornerFrame(corner)
        applyFrame(animated: false)
    }

    // MARK: Content

    /// Live camera preview (replaces any still image).
    func attach(_ capture: CameraCapture) {
        bubbleView.setPreviewLayer(capture.makePreviewLayer())
        bubbleView.still = nil
    }

    /// A still image instead of the camera (test pattern, last frame). `nil`
    /// = the dark placeholder.
    func showStill(_ image: CGImage?) {
        bubbleView.setPreviewLayer(nil)
        bubbleView.still = image
    }

    // MARK: Fullscreen

    func toggleFullscreen() { setFullscreen(!isFullscreen) }

    func setFullscreen(_ fullscreen: Bool, animated: Bool = false) {
        guard fullscreen != isFullscreen else { return }
        isFullscreen = fullscreen
        applyAppearance()
        guard recordedRect.width > 0 else { return }
        bubbleFrame = fullscreen ? recordedRect : cornerFrame(corner)
        applyFrame(animated: animated)
    }

    // MARK: Drag (screen points; the view forwards mouse events)

    func beginDrag(at mouse: CGPoint) {
        guard !isFullscreen else { return }
        dragStartFrame = bubbleFrame
        dragStartMouse = mouse
    }

    func drag(to mouse: CGPoint) {
        guard let start = dragStartFrame else { return }
        let delta = CGVector(dx: mouse.x - dragStartMouse.x, dy: mouse.y - dragStartMouse.y)
        bubbleFrame = CameraLayout.dragged(start, by: delta, in: recordedRect)
        applyFrame(animated: false)
    }

    /// Snaps to the nearest corner.
    func endDrag(animated: Bool = true) {
        guard dragStartFrame != nil else { return }
        dragStartFrame = nil
        let snapped = CameraLayout.snapped(bubbleFrame, in: recordedRect, margin: Tokens.Recording.cameraMargin, yAxis: .up)
        let newCorner = CameraCorner(rawValue: snapped.corner.rawValue) ?? .bottomRight
        bubbleFrame = snapped.frame
        applyFrame(animated: animated)
        if newCorner != corner {
            corner = newCorner
            options.corner = newCorner
            onCornerChange?(newCorner)
        }
    }

    // MARK: Snapshot

    /// The bubble drawn in-process (`cacheDisplay`: the still image or the
    /// placeholder; the live preview layer isn't included). Window-sized,
    /// shadow padding included.
    func snapshot() -> NSBitmapImageRep? {
        bubbleView.layoutSubtreeIfNeeded()
        guard let rep = bubbleView.bitmapImageRepForCachingDisplay(in: bubbleView.bounds) else { return nil }
        bubbleView.cacheDisplay(in: bubbleView.bounds, to: rep)
        return rep
    }

    // MARK: Private

    private func applyAppearance() {
        bubbleView.shape = isFullscreen ? nil : studioShape
        bubbleView.mirrored = options.mirrored
        bubbleView.showsShadow = !isFullscreen
    }

    private func applyFrame(animated: Bool) {
        let pad = shadowPadding
        let windowFrame = bubbleFrame.insetBy(dx: -pad, dy: -pad)
        bubbleView.bubbleRect = CGRect(x: pad, y: pad, width: bubbleFrame.width, height: bubbleFrame.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.allowsImplicitAnimation = true
                panel.animator().setFrame(windowFrame, display: true)
            }
        } else {
            panel.setFrame(windowFrame, display: true)
        }
    }
}

// MARK: - Panel

/// Borderless, non-activating, transparent panel above the dimmer.
final class WebcamBubblePanel: NSPanel {
    /// Same band as the recording border / overlays; below the control bar.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false // the view draws `Tokens.Recording.cameraShadow`
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        title = "Camera"
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - View

/// Draws the shadow + masked still image (`draw(_:)`, so `cacheDisplay`
/// snapshots it) and hosts the live preview layer in a clipping sublayer.
final class WebcamBubbleView: NSView {
    weak var owner: WebcamBubbleWindow?

    /// `nil` = plain rect (fullscreen).
    var shape: StudioCameraShape? = .squircle { didSet { refresh() } }
    var mirrored = false { didSet { refresh() } }
    var showsShadow = true { didSet { refresh() } }
    /// Mask rect in view coordinates.
    var bubbleRect: CGRect = .zero { didSet { refresh() } }
    var still: CGImage? { didSet { needsDisplay = true } }

    private let clipLayer = CALayer()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        clipLayer.masksToBounds = true
        clipLayer.isHidden = true
        layer?.addSublayer(clipLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var cornerRadius: CGFloat {
        guard let shape else { return 0 }
        return CameraLayout.cornerRadius(shape: shape, size: bubbleRect.size, rectangleRadius: Tokens.Recording.cameraRectangleCornerRadius)
    }

    func maskPath() -> CGPath {
        guard let shape else { return CGPath(rect: bubbleRect, transform: nil) }
        return CameraLayout.maskPath(shape: shape, in: bubbleRect, rectangleRadius: Tokens.Recording.cameraRectangleCornerRadius)
    }

    func setPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        previewLayer?.removeFromSuperlayer()
        previewLayer = layer
        if let layer { clipLayer.addSublayer(layer) }
        clipLayer.isHidden = layer == nil
        refresh()
    }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clipLayer.frame = bubbleRect
        clipLayer.cornerRadius = cornerRadius
        clipLayer.cornerCurve = shape == .circle ? .circular : .continuous
        if let previewLayer {
            previewLayer.frame = clipLayer.bounds
            previewLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        }
        CATransaction.commit()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bubbleRect.width > 0, bubbleRect.height > 0 else { return }
        let path = maskPath()
        if showsShadow {
            let shadow = Tokens.Recording.cameraShadow
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: -shadow.y),
                blur: shadow.blur,
                color: NSColor.black.withAlphaComponent(shadow.opacity).cgColor
            )
            context.addPath(path)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        context.fill(bubbleRect)
        if let still {
            let crop = CameraLayout.aspectFillCrop(
                source: CGSize(width: still.width, height: still.height), bubble: bubbleRect.size
            ).integral
            let image = still.cropping(to: crop) ?? still
            if mirrored {
                context.translateBy(x: bubbleRect.midX, y: 0)
                context.scaleBy(x: -1, y: 1)
                context.translateBy(x: -bubbleRect.midX, y: 0)
            }
            context.interpolationQuality = .high
            context.draw(image, in: bubbleRect)
        }
        context.restoreGState()
    }

    // MARK: Mouse

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return maskPath().contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            owner?.toggleFullscreen()
            return
        }
        owner?.beginDrag(at: NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.drag(to: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        owner?.endDrag()
    }
}
