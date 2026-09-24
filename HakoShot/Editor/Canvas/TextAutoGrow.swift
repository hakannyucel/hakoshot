import CoreGraphics
import CoreText
import Foundation
import HakoKit

/// Keeps a text box wide enough while typing: an auto-width box
/// grows with its longest line; any box is at least as wide as its widest word,
/// so CoreText never has to break a word mid-letters (the WP4.2 renderer issue).
nonisolated enum TextAutoGrow {
    /// Extra pixels so float rounding never makes CoreText wrap a word that "just" fits.
    static let slack: CGFloat = 2

    /// Typographic width of `string` on one line, in the font's units (pixels).
    static func width(of string: String, font: CTFont) -> CGFloat {
        guard !string.isEmpty else { return 0 }
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Width of the widest whitespace-separated word.
    static func widestWordWidth(_ text: String, font: CTFont) -> CGFloat {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .map { width(of: String($0), font: font) }
            .max() ?? 0
    }

    /// Width of the longest line when nothing wraps (trailing spaces included, so
    /// the caret has room while typing).
    static func naturalWidth(_ text: String, font: CTFont) -> CGFloat {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { width(of: String($0), font: font) }
            .max() ?? 0
    }

    /// Frame for `shape` after an edit.
    /// - `autoWidth`: width follows the longest line (clamped to `maxWidth` if given).
    /// - Otherwise the width is kept, but never below the widest word.
    /// - Height always fits the laid-out text.
    static func fittedFrame(for shape: TextShape, autoWidth: Bool, maxWidth: CGFloat? = nil) -> CGRect {
        let font = TextLayout.font(for: shape.textStyle, size: shape.fontSize)
        let minimumCaretWidth = shape.fontSize * 0.6
        let wordWidth = (widestWordWidth(shape.text, font: font) + slack).rounded(.up)
        var width: CGFloat
        if autoWidth {
            width = max((naturalWidth(shape.text, font: font) + slack).rounded(.up), minimumCaretWidth)
            if let maxWidth, maxWidth > 0 { width = min(width, maxWidth) }
        } else {
            width = shape.frame.width
        }
        width = max(width, wordWidth, 1)
        var fitted = shape
        fitted.frame.size.width = width
        let height = TextLayout.fittedHeight(for: fitted)
        return CGRect(x: shape.frame.minX, y: shape.frame.minY, width: width, height: height)
    }

    /// Whether a box currently hugs its text (so further edits keep auto-growing).
    static func isAutoWidth(_ shape: TextShape) -> Bool {
        let font = TextLayout.font(for: shape.textStyle, size: shape.fontSize)
        let natural = max((naturalWidth(shape.text, font: font) + slack).rounded(.up), shape.fontSize * 0.6)
        return abs(shape.frame.width - natural) <= 1.5
    }
}
