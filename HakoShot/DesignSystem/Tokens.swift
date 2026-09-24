import AppKit
import QuartzCore
import SwiftUI

/// HakoShot design tokens. Source: the UI design report ("HakoShot için
/// tasarım token önerileri") and plan §4.12 where the plan overrides the report.
///
/// Every measured value in the report was read off marketing screenshots, so all
/// sizes here are estimates unless marked otherwise. `// est.` = estimated from
/// screenshots; `// sugg.` = report/HIG suggestion, not observed at all.
///
/// Tokens are `nonisolated` so overlay/layer code off the main actor can read them.
nonisolated enum Tokens {

    // MARK: - Colors

    enum Palette {
        /// System accent (report suggests binding to the user's accent instead of a fixed blue).
        static var accent: NSColor { .controlAccentColor }

        // Annotation defaults (sugg.; exact hex not verifiable).
        static let annotationStroke = NSColor(hex: 0xFF375F)
        static let annotationCounterFill = NSColor(hex: 0xFF375F)
        static let annotationHighlighter = NSColor(hex: 0xFFEB3B, alpha: 0.45)

        // Light UI surfaces (settings, editor). Light values from report (est.), dark values sugg.
        static let settingsCard = NSColor.dynamic(light: NSColor(hex: 0xF5F5F7), dark: NSColor(hex: 0x262628))
        static let settingsCardBorder = NSColor.dynamic(
            light: NSColor(white: 0, alpha: 0.05),
            dark: NSColor(white: 1, alpha: 0.06)
        )
        static let divider = NSColor.dynamic(light: NSColor(hex: 0xE5E5EA), dark: NSColor(hex: 0x38383A))
        /// Selected sidebar row / neutral hover fill (est.).
        static let selectionFill = NSColor.dynamic(
            light: NSColor(white: 0, alpha: 0.08),
            dark: NSColor(white: 1, alpha: 0.10)
        )
        /// Neutral pill fill on light surfaces ("Save as…", "Choose…"; est.).
        static let neutralPillFill = NSColor.dynamic(
            light: NSColor(white: 0, alpha: 0.07),
            dark: NSColor(white: 1, alpha: 0.12)
        )

        static var textPrimary: NSColor { .labelColor }
        static var textSecondary: NSColor { .secondaryLabelColor }

        // HUD language: always dark, theme-independent (report §3, §13).
        /// Hover scrim over Quick Access / Pin (plan §4.12: 65 % black).
        static let hudScrim = NSColor(white: 0, alpha: 0.65)
        /// Dark translucent fill for circle buttons / dark pills on HUD (est.).
        static let hudControlFill = NSColor(white: 0.08, alpha: 0.72)
        static let hudControlFillHover = NSColor(white: 0.18, alpha: 0.82)
        /// Light pill on HUD ("Copy", "Save", "Done"; est.).
        static let hudLightFill = NSColor(white: 0.96, alpha: 0.96)
        static let hudLightFillHover = NSColor(white: 1, alpha: 1)
        /// Highlight behind the hovered item in the All-In-One bar (est.).
        static let hudItemHighlight = NSColor(white: 1, alpha: 0.14)
        static let hudTextPrimary = NSColor.white
        static let hudTextSecondary = NSColor(white: 1, alpha: 0.62)
        static let hudTextOnLight = NSColor(white: 0.08, alpha: 1)
        /// Outside-selection dimming (report §4: 50–60 %, est.).
        static let selectionDim = NSColor(white: 0, alpha: 0.55)
        /// Crop mode dimming (report §9.4: 70–80 %, est.).
        static let cropDim = NSColor(white: 0, alpha: 0.75)
        /// Hairline border on HUD panels so they separate from dark wallpapers (sugg.).
        static let hudBorder = NSColor(white: 1, alpha: 0.10)
    }

    // MARK: - Radii (pt, all est.)

    enum Radius {
        static let swatchSmall: CGFloat = 10
        static let toolHighlight: CGFloat = 8          // editor active tool bg
        static let hudItemHighlight: CGFloat = 11      // All-In-One hovered item
        static let settingsCard: CGFloat = 12
        static let settingsIconBadge: CGFloat = 9
        static let sidebarRow: CGFloat = 10
        static let quickAccessCard: CGFloat = 14
        static let pinWindow: CGFloat = 12             // plan §4.12
        static let magnifier: CGFloat = 16
        static let toastBadge: CGFloat = 15            // OCR "⌘V" badge
        static let windowOuter: CGFloat = 18
        static let historyCard: CGFloat = 18
        static let modal: CGFloat = 16
        static let hudBar: CGFloat = 32                // All-In-One bar: half-pill ends (64 pt bar; report 28–32)
        // Pills are fully rounded: use `Capsule()` / height / 2.
    }

    // MARK: - Shadows

    /// CSS-like token (`0 y blur rgba(0,0,0,opacity)`). SwiftUI's and CALayer's shadow
    /// radius is roughly half the CSS blur, which `radius` returns.
    struct Shadow: Sendable {
        let opacity: Double
        let blur: CGFloat
        let y: CGFloat
        var radius: CGFloat { blur / 2 }

        static let floatingCard = Shadow(opacity: 0.18, blur: 24, y: 8)   // sugg.
        static let hudBar = Shadow(opacity: 0.35, blur: 20, y: 6)         // sugg.
        static let settingsCard = Shadow(opacity: 0.04, blur: 2, y: 1)    // sugg. (almost none)
        static let toast = Shadow(opacity: 0.25, blur: 16, y: 4)          // sugg.
    }

    // MARK: - Spacing (8 pt grid, sugg.)

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32

        static let settingsRowV: CGFloat = 12
        static let settingsRowH: CGFloat = 16
        static let settingsRowTextGap: CGFloat = 2
        static let settingsSectionHeaderGap: CGFloat = 8
        static let cardGap: CGFloat = 20
        static let swatchGap: CGFloat = 11
        static let hudBarPaddingH: CGFloat = 22
        static let hudItemGap: CGFloat = 26
        static let hoverControlInset: CGFloat = 8      // corner buttons from card edge
        static let hoverPillGap: CGFloat = 8           // Copy / Save stack
        static let pillPaddingH: CGFloat = 14
        static let pillIconGap: CGFloat = 5
        static let quickAccessScreenInset: CGFloat = 20 // plan §4.12
        static let quickAccessStackGap: CGFloat = 12
    }

    // MARK: - Component sizes (est.)

    enum Size {
        static let circleButton: CGFloat = 30          // plan §4.12
        static let circleButtonIcon: CGFloat = 12
        static let pillHeight: CGFloat = 28
        static let pillMinWidth: CGFloat = 72
        static let hudIcon: CGFloat = 21
        static let settingsIconBadge: CGFloat = 36
        static let magnifier: CGFloat = 96
        static let crosshairCircle: CGFloat = 8
        static let selectionHandle: CGFloat = 10
        static let counterBadge: CGFloat = 30
        static let toastBadge: CGFloat = 60
        static let quickAccessCardWidth: CGFloat = 200 // plan §4.12 default
        static let editorToolButton: CGFloat = 32
        static let swatch: CGFloat = 64
        static let colorDot: CGFloat = 28
    }

    // MARK: - Stroke widths

    enum Stroke {
        // Annotation stroke presets (sugg.; toolbar showed "20 pt"/"30 pt").
        static let thin: CGFloat = 2
        static let `default`: CGFloat = 4
        static let medium: CGFloat = 8
        static let thick: CGFloat = 12
        static let extraThick: CGFloat = 20
        static let annotationPresets: [CGFloat] = [thin, `default`, medium, thick, extraThick]

        // UI strokes (est.).
        static let hairline: CGFloat = 1
        static let crosshair: CGFloat = 1
        static let magnifierBorder: CGFloat = 2
        static let selectionRing: CGFloat = 3          // history card / swatch selection
        static let settingsThumbRing: CGFloat = 2
    }

    // MARK: - Typography (SF system font; sizes sugg.)

    enum Typography {
        static let settingsTitle = Font.system(size: 23, weight: .bold)
        static let sectionHeader = Font.system(size: 14, weight: .semibold)
        static let rowLabel = Font.system(size: 13, weight: .regular)
        static let rowDescription = Font.system(size: 11, weight: .regular)
        static let dimensionLabel = Font.system(size: 12, weight: .medium).monospacedDigit()
        static let hudLabel = Font.system(size: 11, weight: .regular)
        static let pillLabel = Font.system(size: 13, weight: .medium)
        static let toastGlyph = Font.system(size: 22, weight: .bold)

        /// AppKit counterparts for CALayer/CATextLayer drawing.
        static var dimensionLabelNS: NSFont { .monospacedDigitSystemFont(ofSize: 12, weight: .medium) }
        static var hudLabelNS: NSFont { .systemFont(ofSize: 11) }
    }

    // MARK: - Motion (all sugg.; nothing measurable from stills)

    enum Duration {
        static let popoverIn: TimeInterval = 0.15
        static let overlayFadeIn: TimeInterval = 0.20
        static let quickAccessSlideIn: TimeInterval = 0.25
        static let quickAccessSpringDamping: Double = 0.8
        static let hoverControlsFade: TimeInterval = 0.12
        static let copyFlash: TimeInterval = 0.35
        static let toastIn: TimeInterval = 0.15
        static let toastHold: TimeInterval = 1.35
        static let toastOut: TimeInterval = 0.20
    }
}

// MARK: - SwiftUI bridges

extension Color {
    static var dsAccent: Color { .accentColor }
    static var dsSettingsCard: Color { Color(nsColor: Tokens.Palette.settingsCard) }
    static var dsDivider: Color { Color(nsColor: Tokens.Palette.divider) }
    static var dsHudScrim: Color { Color(nsColor: Tokens.Palette.hudScrim) }
    static var dsHudControlFill: Color { Color(nsColor: Tokens.Palette.hudControlFill) }
    static var dsHudLightFill: Color { Color(nsColor: Tokens.Palette.hudLightFill) }
}

extension View {
    /// Applies a shadow token.
    func dsShadow(_ token: Tokens.Shadow) -> some View {
        shadow(color: .black.opacity(token.opacity), radius: token.radius, x: 0, y: token.y)
    }
}

extension CALayer {
    /// Applies a shadow token to a layer (AppKit coordinates: positive y goes up, so offset is negated).
    nonisolated func applyShadow(_ token: Tokens.Shadow, flipped: Bool = false) {
        shadowColor = NSColor.black.cgColor
        shadowOpacity = Float(token.opacity)
        shadowRadius = token.radius
        shadowOffset = CGSize(width: 0, height: flipped ? token.y : -token.y)
    }
}

// MARK: - NSColor helpers

extension NSColor {
    nonisolated convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Appearance-aware color (light / dark).
    nonisolated static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }
}
