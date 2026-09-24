import AppKit
import QuartzCore

/// Freeze Screen backdrop (plan §4.2): the display snapshot taken before the
/// overlay appeared, drawn under everything else so the user selects on a
/// still image (open menus and tooltips stay visible).
final class FrozenBackdropLayer {
    let layer = CALayer()

    init() {
        layer.contentsGravity = .resize
        layer.isOpaque = true
        OverlayLayerActions.disable([layer])
        layer.isHidden = true
    }

    /// `image` covers the whole display; `nil` hides the backdrop (live screen shows through).
    func update(image: CGImage?) {
        layer.contents = image
        layer.isHidden = image == nil
    }
}
