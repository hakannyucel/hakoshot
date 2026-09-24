import AppKit
import SwiftUI

/// Per-surface design tokens (M7 consolidation). These were local enums in
/// the feature folders (`PinTokens`, `HistoryMetrics`, Quick Access layout
/// constants, `EditorMetrics`, All-In-One metrics); the shared visual values
/// live here now. Interaction constants (scroll rates, nudge steps, hit
/// bands, timers) stay next to their feature. Values unchanged: `// est.` =
/// estimated from the UI report's screenshots, `// sugg.` = our choice.
extension Tokens {

    // MARK: - All-In-One bar (UI report §3, `ss_all-in-one.png`, est.)

    nonisolated enum AllInOne {
        static let itemWidth: CGFloat = 64
        static let itemHeight: CGFloat = 50
        static let itemGap: CGFloat = 2
        static let iconSize: CGFloat = 19
        static let iconLabelGap: CGFloat = 4
        static let barPaddingH: CGFloat = 8
        static let barPaddingV: CGFloat = 7
        static let barGap: CGFloat = 10
        static let sizeFieldWidth: CGFloat = 54
        static let sizeFieldHeight: CGFloat = 26
        static let sizeFieldRadius: CGFloat = 7
        static let menuWidth: CGFloat = 176
        static let menuRowHeight: CGFloat = 24
        static let menuRadius: CGFloat = 12
        static let fieldFill = Color.white.opacity(0.10)
        static let hoverFill = Color.white.opacity(0.08)
    }

    // MARK: - Quick Access (UI report §7, plan §4.12)

    nonisolated enum QuickAccess {
        /// Transparent margin around each card inside its panel so the shadow isn't clipped.
        static let shadowMargin: CGFloat = 24
        /// Card height / width limits: very wide or tall captures are cropped (aspect fill; sugg.).
        static let minAspect: CGFloat = 0.4
        static let maxAspect: CGFloat = 1.25
    }

    // MARK: - Pin (UI report §8)

    nonisolated enum Pin {
        /// Dark gradient strip behind the hover bar ("ince, koyu yarı saydam şerit"; est.).
        static let hoverStripHeight: CGFloat = 46
        static let hoverStripOpacity: CGFloat = 0.45
        /// Gap between the hover bar's trailing controls (sugg.).
        static let hoverBarItemGap: CGFloat = 6
        /// Zoom badge pill is narrower than a normal pill (sugg.).
        static let zoomBadgeMinWidth: CGFloat = 52
        /// Opacity / zoom / "Copied" HUD: how long it stays before fading (sugg.).
        static let hudHold: TimeInterval = 0.8
        /// Hairline border when "border" is on (sugg.).
        static let borderColor = NSColor(white: 0.5, alpha: 0.55)
    }

    // MARK: - Capture History overlay (UI report §10, est.)

    nonisolated enum History {
        /// Selected card height as a fraction of the screen height, capped.
        static let selectedCardHeightFraction: CGFloat = 0.42
        static let selectedCardMaxHeight: CGFloat = 440
        /// Unselected cards relative to the selected card.
        static let sideCardScale: CGFloat = 0.62
        /// Card width limits relative to its height (very tall / very wide captures).
        static let minAspect: CGFloat = 0.5
        static let maxAspect: CGFloat = 2.4
        static let cardGap: CGFloat = Spacing.xl
        static let topInset: CGFloat = 56
        static let bottomInset: CGFloat = 40
        /// Extra darkening over the HUD blur so the cards pop (report §10: dark blur).
        static let backdropTint: Double = 0.35
    }

    // MARK: - Annotation editor (UI report §9, plan §4.11)

    nonisolated enum Editor {
        /// Full-width top bar (plan §4.11: 52 pt) and bottom bar (est.).
        static let toolbarHeight: CGFloat = 52
        static let bottomBarHeight: CGFloat = 56
        /// 30 pt: 12 tools must fit next to the options at the minimum window width.
        static let toolButtonSize: CGFloat = 30
        static let toolIconSize: CGFloat = 15
        static let optionControlHeight: CGFloat = 26
        static let optionColorDot: CGFloat = 20
        static let paletteSwatch: CGFloat = 24

        /// Canvas background around the image (report §9.2: white / light gray; dark sugg.).
        static let canvasBackground = NSColor.dynamic(light: NSColor(hex: 0xE8E8EB), dark: NSColor(hex: 0x1E1E20))
        /// Gray border around the image at 100 % (sugg.).
        static let canvasMargin: CGFloat = 36
        /// Soft shadow under the image (report §9.2, sugg.).
        static let imageShadowBlur: CGFloat = 18
        static let imageShadowOpacity: CGFloat = 0.18
        static let imageShadowOffsetY: CGFloat = 3
        /// Checkerboard behind transparent pixels.
        static let checkerSize: CGFloat = 8
        static let checkerLight = NSColor(white: 1, alpha: 1)
        static let checkerDark = NSColor(white: 0.9, alpha: 1)

        /// Selection chrome (report §9.2).
        static let handleBorderWidth: CGFloat = 1.5
        static let marqueeFillOpacity: CGFloat = 0.12

        /// Crop mode (report §9.4: ~10 px squares).
        static let cropHandleSize: CGFloat = 9
        static let cropGuideOpacity: CGFloat = 0.45

        /// Background panel (report §9.3: ~280–300 pt sidebar).
        static let backgroundPanelWidth: CGFloat = 288
        static let backgroundPanelPadding: CGFloat = 14
        static let backgroundSwatchRadius: CGFloat = 9
        static let backgroundColorDot: CGFloat = 26
        static let backgroundSelectionRing: CGFloat = 2.5
        static let backgroundAlignmentCell: CGFloat = 18
    }

    // MARK: - Onboarding (M7)

    nonisolated enum Onboarding {
        static let windowSize = CGSize(width: 560, height: 440)
        static let contentPaddingH: CGFloat = Spacing.xxl
        static let contentPaddingTop: CGFloat = 44          // clears the transparent title bar
        static let heroIcon: CGFloat = 96
        static let badge: CGFloat = Size.settingsIconBadge
        static let badgeSymbol: CGFloat = 17
        static let statusSymbol: CGFloat = 20
        static let doneSymbol: CGFloat = 56
        static let comboColumn: CGFloat = 52
        static let shortcutRowV: CGFloat = 7
        static let dot: CGFloat = 6
    }

    // MARK: - Self-Timer HUD (plan §4.14; the UI report had no reference)

    nonisolated enum SelfTimer {
        /// Dark HUD circle diameter.
        static let diameter: CGFloat = 120
        /// Big white digit: SF Pro Rounded 64 pt Bold.
        static let digitSize: CGFloat = 64
        /// Each new digit starts at this scale and settles to 1.
        static let pulseScale: CGFloat = 1.2
        static let pulseDuration: TimeInterval = 0.35
        /// Extra room around the circle for its shadow.
        static let shadowInset: CGFloat = 16
    }

    // MARK: - Scrolling capture UI (UI report §4, plan §4.8)

    nonisolated enum Scrolling {
        /// Live thumbnail: bottom-left, Quick Access inset (report §4).
        static let thumbnailInset = Spacing.quickAccessScreenInset
        static let thumbnailMaxWidth: CGFloat = 150
        static let thumbnailMaxHeightFraction: CGFloat = 0.55
        static let thumbnailCornerRadius: CGFloat = 10          // report §4: ~8–10 pt
        static let thumbnailBorder = Palette.hudBorder
        static let thumbnailShadow = Shadow.floatingCard
        /// Refresh rate cap of the thumbnail (WP6.1: ≤ 4 Hz).
        static let previewInterval: Swift.Duration = .milliseconds(250)
        /// Longest side of the preview bitmap, pixels.
        static let previewMaxPixels = 600

        /// Auto-Scroll button on the selection's right edge (report §4: ~28 pt).
        static let sideButtonDiameter = Size.circleButton
        static let sideButtonGap = Spacing.s
        static let sideTrackWidth: CGFloat = 3

        /// Controls: bottom-center of the display.
        static let controlsBottomInset: CGFloat = 64
        static let controlsSize = CGSize(width: 560, height: 150)
        static let controlsSpacing = Spacing.s
        static let hintFont = Font.system(size: 13, weight: .medium)
        static let permissionCardWidth: CGFloat = 380
    }
}
