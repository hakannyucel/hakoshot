import AppKit
import SwiftUI

/// Screen-recording design tokens (kayit-teknik-plan §4.2–§4.9, §4.16, §4.19,
/// §5.2). Skeleton written by the orchestrator before the recording packages;
/// UI packages use these instead of literal numbers (plan §7.0) and report
/// new or changed values to the orchestrator. `// verified` = seen in
/// CleanShot's official material, `// est.` = estimated from screenshots,
/// `// sugg.` = our choice (plan "varsayılan seçim").
extension Tokens {
    nonisolated enum Recording {

        // MARK: Colors

        /// Click highlight ring default color `#0A84FF` (observed blue; sugg. value).
        static let clickColor = NSColor(hex: 0x0A84FF)
        /// Record button, stop dot, menu bar recording dot (sugg.: system red).
        static let recordRed = NSColor(hex: 0xFF3B30)
        /// Outside-area dimming while recording: black 40 % (sugg.). Not on fullscreen.
        static let dim = NSColor(white: 0, alpha: 0.40)

        // MARK: Recording area border (plan §4.4: 1 pt white + 1 pt black, 2 pt outside the area; sugg.)

        static let borderGap: CGFloat = 2
        static let borderLineWidth = Stroke.hairline
        static let borderInnerColor = NSColor.white
        static let borderOuterColor = NSColor.black

        // MARK: Control bar (plan §4.4: 40 pt dark pill, bottom-center, 24 pt from the bottom)

        static let controlBarHeight: CGFloat = 40                   // sugg.
        static let controlBarBottomInset: CGFloat = 24              // sugg.
        static let controlBarRadius: CGFloat = controlBarHeight / 2
        static let controlBarFill = Palette.hudControlFill
        static let controlBarBorder = Palette.hudBorder
        static let controlBarShadow = Shadow.hudBar
        static let controlBarPaddingH: CGFloat = 6                  // est.
        static let controlSegmentWidth: CGFloat = 36                // est.
        static let controlIconSize: CGFloat = 15                    // est.
        static let controlDividerOpacity: CGFloat = 0.18            // est.
        /// Red stop dot in the first segment (est.).
        static let stopDotDiameter: CGFloat = 12
        /// `mm:ss` / `h:mm:ss` timer (sugg.).
        static let timerFont = Font.system(size: 13, weight: .medium).monospacedDigit()
        static var timerFontNS: NSFont { .monospacedDigitSystemFont(ofSize: 13, weight: .medium) }
        /// Mic level bar inside the stop segment (sugg.).
        static let levelBarWidth: CGFloat = 3
        static let levelBarHeight: CGFloat = 16
        /// Stop segment width: dot + `h:mm:ss` + the mic level bar, fixed so the bar
        /// never resizes while the timer text grows (R1.2, sugg.).
        static let controlStopSegmentWidth: CGFloat = 108

        // MARK: Countdown (plan §4.3: mirrors the Self-Timer HUD, `Tokens.SelfTimer`; R1.2)

        static let countdownDiameter = Tokens.SelfTimer.diameter
        static let countdownDigitSize = Tokens.SelfTimer.digitSize
        static let countdownPulseScale = Tokens.SelfTimer.pulseScale
        static let countdownPulseDuration = Tokens.SelfTimer.pulseDuration
        static let countdownShadowInset = Tokens.SelfTimer.shadowInset

        // MARK: Pre-record HUD (plan §4.2; two dark pills, reuses All-In-One metrics)

        static let hudPillGap = Spacing.s                           // est.
        static let hudBottomInset = Overlay.accessoryBottomInset
        static let hudToggleSize: CGFloat = 32                      // est.
        static let hudToggleIconSize = Size.hudIcon
        static let hudRecordButtonHeight: CGFloat = 32              // est.
        static let hudRecordButtonPaddingH: CGFloat = 14            // est.
        static let hudLevelBarWidth: CGFloat = 60                   // sugg.

        // MARK: Click highlight ring (plan §4.9, §5.2; sugg.)

        static let clickLineWidth: CGFloat = 2
        static let clickStartRadius: CGFloat = 18
        static let clickEndRadius: CGFloat = 30
        static let clickDuration: TimeInterval = 0.35
        /// Filled style fill opacity (sugg.).
        static let clickFillOpacity: CGFloat = 0.35
        /// Radius multiplier per `RecordingElementSize` (small, medium, large; sugg.).
        static func clickScale(_ size: RecordingElementSize) -> CGFloat {
            switch size {
            case .small: 0.75
            case .medium: 1
            case .large: 1.4
            }
        }

        // MARK: Keystroke badge (plan §4.9, §5.2; sugg.)

        static func keystrokeBadgeHeight(_ size: RecordingElementSize) -> CGFloat {
            switch size {
            case .small: 34
            case .medium: 44
            case .large: 56
            }
        }
        static let keystrokeBottomInset: CGFloat = 64
        static let keystrokePaddingH: CGFloat = 16                  // sugg.
        static let keystrokeDarkFill = Palette.hudControlFill
        static let keystrokeDarkText = Palette.hudTextPrimary
        static let keystrokeLightFill = Palette.hudLightFill
        static let keystrokeLightText = Palette.hudTextOnLight
        static let keystrokeFadeIn: TimeInterval = 0.2
        static let keystrokeHold: TimeInterval = 1.2
        static let keystrokeFadeOut: TimeInterval = 0.2
        /// Repeat pulse "⌘Z ×3": 1.1 → 1.
        static let keystrokePulseScale: CGFloat = 1.1

        // MARK: Webcam bubble (plan §4.8, §5.2)

        static func cameraSize(_ size: RecordingElementSize) -> CGFloat {
            switch size {
            case .small: 140
            case .medium: 180
            case .large: 240
            }
        }
        static let cameraMargin: CGFloat = 24                       // sugg.
        /// Squircle corner radius as a fraction of the side (observed ~18–22 %).
        static let cameraSquircleCornerFraction: CGFloat = 0.22
        static let cameraRectangleCornerRadius: CGFloat = 12        // sugg.
        static let cameraShadow = Shadow.floatingCard

        // MARK: Menu bar timer (plan §4.4)

        static var menuBarTimerFont: NSFont { .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular) }
        static let menuBarDotDiameter: CGFloat = 8                  // sugg.

        // MARK: Quick Access video card + History filmstrip (plan §4.15; R0.4 added `durationBadgeGlyphSize`)

        static let durationBadgeHeight: CGFloat = 20                // sugg.
        static let durationBadgeInset = Spacing.s
        static let durationBadgeFont = Font.system(size: 11, weight: .semibold).monospacedDigit()
        /// The ▶︎ glyph inside the duration badge (History filmstrip card; sugg.).
        static let durationBadgeGlyphSize: CGFloat = 9

        // MARK: Video editor (plan §4.16; sugg.)

        static let editorTimelineHeight: CGFloat = 64
        static let editorThumbnailWidth: CGFloat = 48
        static let editorTrimHandleColor = NSColor(hex: 0xFFD60A)   // QuickTime-like yellow
        static let editorTrimHandleWidth: CGFloat = 10
        static let editorTrimmedDimOpacity: CGFloat = 0.5
        static let editorPlayheadColor = NSColor.white
        static let editorToolbarHeight = Editor.toolbarHeight

        // MARK: Studio (plan §4.19; sugg.)

        static let studioInspectorWidth: CGFloat = 300
        static let studioLaneHeight: CGFloat = 36
        static let studioZoomSegmentColor = NSColor(hex: 0x5E5CE6)
        static let studioClickMarkerDiameter: CGFloat = 6
    }
}

// MARK: - R1.1 pre-record HUD (added by R1.1; `RecordingOptionsBar`, `RecordFormatMenu`)

extension Tokens.Recording {
    /// Inner padding of each HUD pill; pill height = `hudToggleSize` + 2 × this = 40 pt
    /// (same as the control bar; est.).
    nonisolated static let hudPillPaddingV = Tokens.Spacing.xs
    nonisolated static let hudPillPaddingH = Tokens.Spacing.s
    nonisolated static var hudPillHeight: CGFloat { hudToggleSize + hudPillPaddingV * 2 }
    nonisolated static var hudPillRadius: CGFloat { hudPillHeight / 2 }
    /// Gap between toggles in the lower pill (est.).
    nonisolated static let hudToggleGap = Tokens.Spacing.xxs
    nonisolated static let hudToggleRadius = Tokens.Radius.toolHighlight
    /// SF Symbol point size inside a 32 pt toggle (est.).
    nonisolated static let hudToggleGlyphSize: CGFloat = 15
    /// The device-menu arrow next to the microphone / on the Record button (points up: menus open upward; sugg.).
    nonisolated static let hudChevronGlyphSize: CGFloat = 9
    nonisolated static let hudChevronWidth: CGFloat = 16
    /// Vertical hairline between toggle groups (sugg.).
    nonisolated static let hudDividerHeight: CGFloat = 20
    /// Record button: red pill, `hudRecordButtonHeight` tall; the ⌄ segment (sugg.).
    nonisolated static let hudRecordChevronWidth: CGFloat = 24
    nonisolated static let hudRecordDotDiameter: CGFloat = 8
    nonisolated static let hudRecordSegmentDividerOpacity: CGFloat = 0.35
    /// Dropdown menus (format, microphone, options) (sugg.).
    nonisolated static let hudFormatMenuWidth: CGFloat = 264
    nonisolated static let hudOptionsMenuWidth: CGFloat = 212
    nonisolated static let hudMenuPadding: CGFloat = 6
    nonisolated static let hudMenuIconSize: CGFloat = 12
    nonisolated static let hudMenuIconWidth: CGFloat = 26
    /// White "GIF" badge in the format menu (CleanShot `format.png`; est.).
    nonisolated static let hudGIFBadgeFont = Font.system(size: 8, weight: .heavy)
    nonisolated static let hudGIFBadgePaddingH: CGFloat = 3
    nonisolated static let hudGIFBadgeRadius: CGFloat = 3
    /// Placeholder toggles (camera until R4) (sugg.).
    nonisolated static let hudUnavailableOpacity: CGFloat = 0.4
    /// Transparent room around the pills for the HUD shadow (same as All-In-One).
    nonisolated static let hudShadowMargin = Tokens.Spacing.l
}

// MARK: - Do Not Disturb setup sheet (R1.4) and display picker (R1.I)

extension Tokens.Recording {
    /// Do Not Disturb setup sheet width (sugg.).
    static let dndSetupSheetWidth: CGFloat = 480
    /// Step number badge in the sheet (sugg.).
    static let dndSetupStepBadge: CGFloat = 22
    /// Shortcut name field width in the sheet (sugg.).
    static let dndSetupFieldWidth: CGFloat = 190
    /// Fullscreen display picker: tint over each display (sugg.).
    static let displayPickerTint = NSColor(white: 0, alpha: 0.35)
    /// Tint over the display under the pointer (sugg.).
    static let displayPickerHoverTint = NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 0.22)
    /// The centered "Click to record this display" label (sugg.).
    static let displayPickerTitleFont = NSFont.systemFont(ofSize: 22, weight: .semibold)
    static let displayPickerHintFont = NSFont.systemFont(ofSize: 13, weight: .regular)
}

// MARK: - Microphone (R2.I)

extension Tokens.Recording {
    /// Silent-microphone warning dot in the control bar (plan §1.4 "sarı nokta").
    static let micSilentColor = NSColor.systemYellow
    static let micSilentDotDiameter: CGFloat = 6
    /// HUD mic menu: wider than the options menu so device names fit.
    static let hudMicrophoneMenuWidth: CGFloat = 280
    /// Settings › Screen Recording microphone / camera pickers: longer names truncate (sugg.).
    static let settingsDevicePickerMaxWidth: CGFloat = 220
}
