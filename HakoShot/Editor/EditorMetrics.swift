import AppKit
import SwiftUI

/// Editor metrics (WP4.3). Visual values forward to `Tokens.Editor` /
/// `Tokens` (M7 consolidation); interaction constants and window geometry
/// (nudge, snapping, cascade, timers) are editor-specific and stay here.
nonisolated enum EditorMetrics {
    // MARK: Window chrome

    /// Full-width top bar holding traffic lights, tools, options and pills (plan §4.11: 52 pt).
    static var toolbarHeight: CGFloat { Tokens.Editor.toolbarHeight }
    /// Bottom bar with zoom, "Drag Me" and quick actions (est.).
    static var bottomBarHeight: CGFloat { Tokens.Editor.bottomBarHeight }
    /// Hairline between the toolbar and the canvas.
    static var separatorHeight: CGFloat { Tokens.Stroke.hairline }
    /// Traffic lights: x of the close button and distance between button origins (sugg.).
    static let trafficLightLeading: CGFloat = 18
    static let trafficLightSpacing: CGFloat = 20
    /// Toolbar content starts after the traffic lights.
    static let toolbarLeadingInset: CGFloat = 86
    static let toolbarTrailingInset: CGFloat = 14
    static let toolbarItemSpacing: CGFloat = 1
    static let toolbarGroupSpacing: CGFloat = 10
    /// Smallest window that still fits the toolbar (sugg.).
    static let minimumWindowSize = CGSize(width: 1100, height: 560)
    /// Fraction of the screen's visible frame a new editor may use (sugg.).
    static let maximumScreenFraction: CGFloat = 0.9
    /// Offset between editors opened one after another (sugg.).
    static let cascadeOffset: CGFloat = 26

    // MARK: Canvas

    /// Gray border around the image inside the scrollable canvas, in points at 100 % (sugg.).
    static var canvasMargin: CGFloat { Tokens.Editor.canvasMargin }
    /// Soft shadow under the image (report §9.2, sugg. values).
    static var imageShadowBlur: CGFloat { Tokens.Editor.imageShadowBlur }
    static var imageShadowOpacity: CGFloat { Tokens.Editor.imageShadowOpacity }
    static var imageShadowOffsetY: CGFloat { Tokens.Editor.imageShadowOffsetY }
    /// Checkerboard behind transparent pixels (report §5 "şeffaf checkerboard").
    static var checkerSize: CGFloat { Tokens.Editor.checkerSize }

    /// Canvas background around the image (report §9.2: white / light gray; dark sugg.).
    static var canvasBackground: NSColor { Tokens.Editor.canvasBackground }
    static var checkerLight: NSColor { Tokens.Editor.checkerLight }
    static var checkerDark: NSColor { Tokens.Editor.checkerDark }

    // MARK: Selection chrome (report §9.2)

    /// Handle diameter in screen points (`Tokens.Size.selectionHandle`).
    static var handleDiameter: CGFloat { Tokens.Size.selectionHandle }
    static var handleBorderWidth: CGFloat { Tokens.Editor.handleBorderWidth }
    static var selectionOutlineWidth: CGFloat { Tokens.Stroke.hairline }
    static var marqueeFillOpacity: CGFloat { Tokens.Editor.marqueeFillOpacity }
    /// Nudge distance for arrow keys, in points (⇧: `nudgeLarge`). Plan §5.4 overlay values.
    static let nudgeSmall: CGFloat = 1
    static let nudgeLarge: CGFloat = 10
    /// ⌘D / paste offset, in points (sugg.).
    static let duplicateOffset: CGFloat = 12

    // MARK: Crop mode (report §9.4)

    /// Handle squares, screen points (report: ~10 px).
    static var cropHandleSize: CGFloat { Tokens.Editor.cropHandleSize }
    static let cropHandleHitDistance: CGFloat = 9
    static var cropBorderWidth: CGFloat { Tokens.Stroke.hairline }
    static var cropGuideOpacity: CGFloat { Tokens.Editor.cropGuideOpacity }
    /// Edge snapping distance, screen points (overlay `SnapEngine` uses 6).
    static let cropSnapDistance: CGFloat = 6
    static let cropSizeFieldWidth: CGFloat = 58

    // MARK: Background panel (report §9.3)

    /// Left sidebar width (report: ~280–300 pt).
    static var backgroundPanelWidth: CGFloat { Tokens.Editor.backgroundPanelWidth }
    static var backgroundPanelPadding: CGFloat { Tokens.Editor.backgroundPanelPadding }
    static let backgroundSwatchColumns = 5
    static var backgroundSwatchGap: CGFloat { Tokens.Spacing.s }
    static var backgroundSwatchRadius: CGFloat { Tokens.Editor.backgroundSwatchRadius }
    static var backgroundColorDot: CGFloat { Tokens.Editor.backgroundColorDot }
    static var backgroundSelectionRing: CGFloat { Tokens.Editor.backgroundSelectionRing }
    static var backgroundAlignmentCell: CGFloat { Tokens.Editor.backgroundAlignmentCell }

    // MARK: Toolbar controls

    /// 30 pt: 12 tools must fit next to the options at the minimum window width
    /// (`Tokens.Size.editorToolButton` is 32).
    static var toolButtonSize: CGFloat { Tokens.Editor.toolButtonSize }
    static var optionControlHeight: CGFloat { Tokens.Editor.optionControlHeight }
    static var toolIconSize: CGFloat { Tokens.Editor.toolIconSize }
    static var optionColorDot: CGFloat { Tokens.Editor.optionColorDot }
    static var paletteSwatch: CGFloat { Tokens.Editor.paletteSwatch }
    static let paletteColumns = 5
    /// Fill opacity used by the rectangle / ellipse "Fill" toggle (sugg.).
    static let shapeFillOpacity: Double = 0.25
    /// Status line ("Saved", "Copied") visible time.
    static let statusDuration: Duration = .seconds(2)
    /// NSColorPanel changes are coalesced into one undo step after this pause.
    static let colorPanelCoalesce: Duration = .milliseconds(700)
}

extension Color {
    static var editorCanvasBackground: Color { Color(nsColor: EditorMetrics.canvasBackground) }
}
