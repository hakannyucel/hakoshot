import AppKit
import SwiftUI

/// Classic video editor metrics (kayit-teknik-plan §4.16). Visual values
/// forward to `Tokens.Recording` / `Tokens.Editor`; the rest are editor-only
/// interaction and layout constants (`// sugg.` = our choice, token candidates).
nonisolated enum VideoEditorMetrics {
    // MARK: Window

    static var toolbarHeight: CGFloat { Tokens.Recording.editorToolbarHeight }
    /// Smallest window that still fits the toolbar and a usable timeline (sugg.).
    static let minimumWindowSize = CGSize(width: 820, height: 520)
    /// Fraction of the visible frame a new window may use (sugg.).
    static let maximumScreenFraction: CGFloat = 0.8
    static let cascadeOffset: CGFloat = 26
    static var playerBackground: NSColor { Tokens.Editor.canvasBackground }
    /// Margin around the video inside the player area (sugg.).
    static let playerInset: CGFloat = 20

    // MARK: Timeline

    static var timelineHeight: CGFloat { Tokens.Recording.editorTimelineHeight }
    static var thumbnailWidth: CGFloat { Tokens.Recording.editorThumbnailWidth }
    static var trimHandleColor: NSColor { Tokens.Recording.editorTrimHandleColor }
    static var trimHandleWidth: CGFloat { Tokens.Recording.editorTrimHandleWidth }
    static var trimmedDimOpacity: CGFloat { Tokens.Recording.editorTrimmedDimOpacity }
    static var playheadColor: NSColor { Tokens.Recording.editorPlayheadColor }
    /// Yellow frame above/below the kept range (QuickTime look; sugg.).
    static let trimBorderWidth: CGFloat = 3
    static let trimCornerRadius: CGFloat = 6
    static let playheadWidth: CGFloat = 2
    static let playheadKnob: CGFloat = 10
    /// Padding around the timeline in the bottom bar (sugg.).
    static let bottomBarPaddingV: CGFloat = 12
    static let bottomBarPaddingH: CGFloat = 16
    static var bottomBarHeight: CGFloat { timelineHeight + bottomBarPaddingV * 2 }
    static let playButtonSize: CGFloat = 32
    static let timeLabelWidth: CGFloat = 118
    /// Thumbnails are generated at this multiple of their point size (Retina).
    static let thumbnailPixelScale: CGFloat = 2

    // MARK: Interaction

    /// Shortest kept range (sugg.): 0.1 s, rounded up to whole frames.
    static let minimumTrimSeconds = 0.1
    /// Preview rebuild debounce after a recipe change (sugg.).
    static let previewDebounce: Duration = .milliseconds(250)
    /// ⇧←/⇧→ step.
    static let largeStepSeconds = 1.0
    /// Crop handle hit distance in view points.
    static let cropHandleHitDistance: CGFloat = 9
    static var cropHandleSize: CGFloat { Tokens.Editor.cropHandleSize }
    static let statusDuration: Duration = .seconds(2)
    static let exportSheetWidth: CGFloat = 340
}
