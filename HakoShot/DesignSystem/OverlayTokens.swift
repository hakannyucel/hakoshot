import AppKit

/// Selection-overlay tokens (plan §4.1, §4.3, §4.4, §5.4), built from the
/// shared `Tokens` where one exists. Moved here from `Overlay/` in M7.
extension Tokens {
    nonisolated enum Overlay {
        // MARK: Selection

        /// Outside-selection dimming. Plan §5.4 says 45 %; `Tokens` has 55 % (WP1.2 deviation).
        static var dimColor: CGColor { Palette.selectionDim.cgColor }
        /// Selection frame: 1 pt white line, then 1 pt black line outside it (plan §4.1).
        static let frameLineWidth = Stroke.hairline
        static let frameInnerColor = NSColor.white
        static let frameOuterColor = NSColor.black

        // MARK: Crosshair

        /// Thin dark lines + small empty circle at the intersection (UI report §1).
        static let crosshairLineWidth = Stroke.crosshair
        static let crosshairCircleDiameter = Size.crosshairCircle
        static let crosshairColor = NSColor.black

        // MARK: Dimension label

        /// 12 pt SF Medium, black text with a white halo (plan §5.4).
        static var labelFont: NSFont { Typography.dimensionLabelNS }
        static let labelTextColor = NSColor.black
        static let labelHaloColor = NSColor.white
        static let labelHaloRadius = Spacing.xxs
        /// Gap between the selection corner / cursor and the label.
        static let labelOffset = Spacing.s

        // MARK: Handles (editable selection)

        static let handleDiameter = Size.selectionHandle
        static let handleFill = NSColor.white
        static let handleBorder = NSColor(white: 0, alpha: 0.45)
        static let handleBorderWidth = Stroke.hairline
        static let handleShadow = Shadow(opacity: 0.30, blur: 4, y: 1)       // sugg.

        // MARK: Window highlight (plan §4.4: accent 20 % fill, 2 pt border, 10 pt corners)

        static let windowFillOpacity: CGFloat = 0.20
        static let windowBorderWidth = Stroke.thin
        static let windowCornerRadius: CGFloat = 10
        static var windowLabelFont: NSFont { .systemFont(ofSize: 13, weight: .medium) }
        static let windowLabelPaddingH = Spacing.m
        static let windowLabelHeight = Size.pillHeight

        // MARK: Magnifier (plan §4.3)

        static let magnifierSize = Size.magnifier
        static let magnifierCornerRadius = Radius.magnifier
        static let magnifierBorderWidth = Stroke.magnifierBorder
        static let magnifierBorderColor = NSColor(white: 0.25, alpha: 1)
        static let magnifierShadow = Shadow.floatingCard
        /// Source square: 15 × 15 device pixels around the cursor.
        static let magnifierPixelCount = 15
        /// Gap between the cursor and the loupe (bottom-right, flips at edges).
        static let magnifierOffset: CGFloat = 20
        static let magnifierGridColor = NSColor(white: 0, alpha: 0.12)
        static let magnifierCenterInner = NSColor.white
        static let magnifierCenterOuter = NSColor.black
        /// Caption under the loupe ("X / Y" or "W × H", then the pixel color).
        static var magnifierCaptionFont: NSFont { Typography.dimensionLabelNS }
        static let magnifierCaptionHeight: CGFloat = 36
        static let magnifierCaptionFill = Palette.hudControlFill
        static let magnifierCaptionText = Palette.hudTextPrimary
        static let magnifierCaptionSecondary = Palette.hudTextSecondary
        static let magnifierSwatch: CGFloat = 10

        // MARK: Accessory (All-In-One HUD)

        /// Gap between the selection and an accessory bar placed under/above it.
        static let accessoryGap = Spacing.m
        /// Distance of the accessory bar from the display's bottom edge when there is no selection.
        static let accessoryBottomInset: CGFloat = 64

        // MARK: Motion

        static let fadeIn = Duration.overlayFadeIn
    }
}
