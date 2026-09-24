import AppKit
import QuartzCore

/// Window-mode highlight over the hovered window (plan §4.4, §5.4): accent
/// fill at 20 %, 2 pt accent border, 10 pt corners, plus an optional window
/// name pill centered in the window. These are the plan's default choices
/// (UI report §2).
///
/// Owns its layers like the other overlay parts (`DimensionLabelLayer`):
/// add `layer` to the view's layer and call `show`/`hide`. Frames are in the
/// view's own (AppKit, bottom-left) coordinates — convert a `LocatedWindow`
/// with `OverlayScreens.localRect(_:in:)`.
final class WindowHighlightLayer {
    /// Container; its frame should match the view's bounds.
    let layer = CALayer()
    private let shape = CAShapeLayer()
    private let labelBackground = CALayer()
    private let label = CATextLayer()
    private var currentText = ""
    private var textSize = CGSize.zero

    static let fillOpacity = Tokens.Overlay.windowFillOpacity
    static let borderWidth = Tokens.Overlay.windowBorderWidth
    static let cornerRadius = Tokens.Overlay.windowCornerRadius
    static var labelFont: NSFont { Tokens.Overlay.windowLabelFont }
    static let labelPaddingH = Tokens.Overlay.windowLabelPaddingH
    static let labelHeight = Tokens.Overlay.windowLabelHeight

    init() {
        shape.lineWidth = Self.borderWidth
        layer.addSublayer(shape)

        labelBackground.backgroundColor = Tokens.Palette.hudControlFill.cgColor
        labelBackground.cornerRadius = Self.labelHeight / 2
        labelBackground.borderColor = Tokens.Palette.hudBorder.cgColor
        labelBackground.borderWidth = Tokens.Stroke.hairline
        layer.addSublayer(labelBackground)

        label.font = Self.labelFont
        label.fontSize = Self.labelFont.pointSize
        label.foregroundColor = Tokens.Palette.hudTextPrimary.cgColor
        label.alignmentMode = .center
        label.truncationMode = .middle
        labelBackground.addSublayer(label)

        OverlayLayerActions.disable([layer, shape, labelBackground, label])
        layer.isHidden = true
    }

    func hide() {
        layer.isHidden = true
    }

    /// Highlights `frame` (view coordinates). `title` (e.g.
    /// `LocatedWindow.displayName`) is drawn as a pill in the middle when the
    /// window is large enough; pass `nil` to omit it.
    func show(frame: CGRect, title: String?, scale: CGFloat) {
        let accent = Tokens.Palette.accent
        // Keep the 2 pt border inside the window frame.
        let inset = frame.insetBy(dx: Self.borderWidth / 2, dy: Self.borderWidth / 2)
        guard inset.width > 0, inset.height > 0 else {
            hide()
            return
        }
        shape.path = CGPath(roundedRect: inset, cornerWidth: Self.cornerRadius, cornerHeight: Self.cornerRadius, transform: nil)
        shape.fillColor = accent.withAlphaComponent(Self.fillOpacity).cgColor
        shape.strokeColor = accent.cgColor
        layoutLabel(title, in: frame, scale: scale)
        layer.isHidden = false
    }

    private func layoutLabel(_ title: String?, in frame: CGRect, scale: CGFloat) {
        guard let title, !title.isEmpty else {
            labelBackground.isHidden = true
            return
        }
        if title != currentText {
            currentText = title
            label.string = title
            let measured = (title as NSString).size(withAttributes: [.font: Self.labelFont])
            textSize = CGSize(width: measured.width.rounded(.up), height: measured.height.rounded(.up))
        }
        let maxWidth = frame.width - 2 * Tokens.Spacing.l
        let width = min(textSize.width + 2 * Self.labelPaddingH, maxWidth)
        guard width >= Self.labelHeight * 2, frame.height >= Self.labelHeight + 2 * Tokens.Spacing.l else {
            labelBackground.isHidden = true
            return
        }
        label.contentsScale = scale
        labelBackground.contentsScale = scale
        labelBackground.frame = CGRect(
            x: (frame.midX - width / 2).rounded(), y: (frame.midY - Self.labelHeight / 2).rounded(),
            width: width, height: Self.labelHeight
        )
        label.frame = CGRect(
            x: Self.labelPaddingH, y: ((Self.labelHeight - textSize.height) / 2).rounded(),
            width: width - 2 * Self.labelPaddingH, height: textSize.height
        )
        labelBackground.isHidden = false
    }
}
