import AVFoundation
import AppKit

/// The editor's video area: an `AVPlayerLayer` (aspect fit, inset from the
/// edges) on the canvas background. Keys (Space, ←/→, ⇧←/→, I/O) are
/// handled by `VideoEditorWindow` so they work whatever has focus; this view
/// only takes clicks (click = play/pause) and hosts the crop overlay above it.
final class PlayerView: NSView {
    let playerLayer = AVPlayerLayer()
    /// Called on a click outside the crop overlay.
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = VideoEditorMetrics.playerBackground.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    /// Area the video is fitted into (bounds minus the inset).
    var contentRect: CGRect {
        bounds.insetBy(dx: VideoEditorMetrics.playerInset, dy: VideoEditorMetrics.playerInset)
    }

    /// The video's rect in view coordinates for frames of `size`.
    func videoRect(for size: CGSize) -> CGRect {
        Self.fittedRect(for: size, in: contentRect)
    }

    /// Aspect-fit `size` in `rect`, pixel-aligned.
    nonisolated static func fittedRect(for size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, rect.width > 0, rect.height > 0 else { return rect }
        let fitted = AVMakeRect(aspectRatio: size, insideRect: rect)
        return CGRect(x: fitted.minX.rounded(), y: fitted.minY.rounded(), width: fitted.width.rounded(), height: fitted.height.rounded())
    }

    override var isFlipped: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = VideoEditorMetrics.playerBackground.cgColor
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = contentRect
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 1 { onClick?() }
    }
}
