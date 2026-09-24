import AppKit

/// Clip view that keeps a document smaller than the viewport centered
/// (instead of pinned to the top-left) at every magnification.
final class CenteringClipView: NSClipView {
    override var isFlipped: Bool { true }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentFrame = documentView?.frame else { return rect }
        if rect.width > documentFrame.width {
            rect.origin.x = documentFrame.midX - rect.width / 2
        }
        if rect.height > documentFrame.height {
            rect.origin.y = documentFrame.midY - rect.height / 2
        }
        return rect
    }
}
