import AppKit
import QuartzCore

/// "W × H" next to the selection while dragging, "X / Y" next to the cursor
/// before a drag (plan §5.4). 12 pt SF Medium, black with a white halo.
final class DimensionLabelLayer {
    let layer = CATextLayer()
    private var currentText = ""
    private var textSize = CGSize.zero

    init() {
        layer.font = Tokens.Overlay.labelFont
        layer.fontSize = Tokens.Overlay.labelFont.pointSize
        layer.foregroundColor = Tokens.Overlay.labelTextColor.cgColor
        layer.alignmentMode = .left
        layer.shadowColor = Tokens.Overlay.labelHaloColor.cgColor
        layer.shadowOpacity = 1
        layer.shadowRadius = Tokens.Overlay.labelHaloRadius
        layer.shadowOffset = .zero
        OverlayLayerActions.disable([layer])
        layer.isHidden = true
    }

    func hide() {
        layer.isHidden = true
    }

    /// Shows `text` just outside the bottom-right corner of `rect` (view
    /// coordinates; a zero-size rect for the cursor), flipping to the other
    /// side when it would leave `bounds`.
    func show(_ text: String, near rect: CGRect, within bounds: CGRect, scale: CGFloat) {
        if text != currentText {
            currentText = text
            layer.string = text
            let measured = (text as NSString).size(withAttributes: [.font: Tokens.Overlay.labelFont])
            textSize = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        }
        layer.contentsScale = scale
        let gap = Tokens.Overlay.labelOffset

        // AppKit coordinates: bottom-right corner is (maxX, minY).
        var x = rect.maxX + gap
        var y = rect.minY - gap - textSize.height
        if x + textSize.width > bounds.maxX {
            x = rect.maxX - gap - textSize.width
            if rect.width < textSize.width + 2 * gap { x = rect.minX - gap - textSize.width }
        }
        if y < bounds.minY {
            y = rect.minY + gap
            if rect.height < textSize.height + 2 * gap { y = rect.maxY + gap }
        }
        x = min(max(x, bounds.minX), bounds.maxX - textSize.width)
        y = min(max(y, bounds.minY), bounds.maxY - textSize.height)

        layer.frame = CGRect(origin: CGPoint(x: x, y: y), size: textSize)
        layer.isHidden = false
    }
}
