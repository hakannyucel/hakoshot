import CoreGraphics
import CoreText
import Foundation

/// CoreText layout for `TextShape` and counter digits (spec: `TextStyle` /
/// `TextShape` doc comments).
///
/// Lines wrap to `frame.width`, start at `frame.origin` (top-left) and use the
/// font's line height. WP4.3 can call `TextLayout(shape:).usedRect` /
/// `TextLayout.fittedHeight(for:)` after editing to keep `frame.height` in sync.
public struct TextLayout {
    struct Line {
        var line: CTLine
        /// Baseline origin in canvas space (y-down).
        var origin: CGPoint
        /// Typographic width without trailing whitespace.
        var width: Double
    }

    public let font: CTFont
    let lines: [Line]
    /// Tight rect around the laid-out lines, in canvas pixels. Its height is
    /// never less than one line, even for empty text.
    public let usedRect: CGRect
    /// Height of one line (ascent + descent + leading).
    public let lineHeight: Double

    // MARK: Fonts

    /// The font for a text style at `size` pixels.
    public static func font(for style: TextStyle, size: Double) -> CTFont {
        switch style {
        case .standard, .outlined, .boxed:
            return systemFont(.emphasizedSystem, size: size)
        case .rounded, .roundBoxed:
            return namedSystemFont(".AppleSystemUIFontRounded-Bold", size: size)
                ?? systemFont(.emphasizedSystem, size: size)
        case .monospaced, .monospacedBoxed:
            return namedSystemFont(".AppleSystemUIFontMonospaced-Semibold", size: size)
                ?? namedSystemFont("Menlo-Bold", size: size)
                ?? systemFont(.userFixedPitch, size: size)
        }
    }

    /// Rounded bold (SF Pro Rounded) used for counter digits.
    static func counterFont(size: Double) -> CTFont {
        font(for: .rounded, size: size)
    }

    private static func systemFont(_ type: CTFontUIFontType, size: Double) -> CTFont {
        CTFontCreateUIFontForLanguage(type, size, nil) ?? CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
    }

    /// `CTFontCreateWithName` silently substitutes a fallback font when the
    /// name is unknown; only accept an exact PostScript-name match.
    private static func namedSystemFont(_ name: String, size: Double) -> CTFont? {
        let font = CTFontCreateWithName(name as CFString, size, nil)
        return (CTFontCopyPostScriptName(font) as String) == name ? font : nil
    }

    // MARK: Layout

    /// Lays out `shape.text` (color is applied at draw time).
    public init(shape: TextShape) {
        self.init(
            text: shape.text,
            font: Self.font(for: shape.textStyle, size: shape.fontSize),
            origin: shape.frame.origin,
            wrapWidth: shape.frame.width,
            alignment: shape.alignment
        )
    }

    init(text: String, font: CTFont, origin: CGPoint, wrapWidth: Double?, alignment: TextAlignmentMode) {
        self.font = font
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let fontLineHeight = ascent + descent + leading
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorFromContextAttributeName: true,
        ]
        let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)
        let length = CFStringGetLength(text as CFString)

        var laidOut: [Line] = []
        var y = 0.0
        if let attributed, length > 0 {
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            let width = wrapWidth.map { max($0, 1) } ?? .greatestFiniteMagnitude
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, width)
                if count <= 0 { count = 1 }
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
                var lineAscent: CGFloat = 0
                var lineDescent: CGFloat = 0
                var lineLeading: CGFloat = 0
                let full = CTLineGetTypographicBounds(line, &lineAscent, &lineDescent, &lineLeading)
                let lineWidth = max(0, full - CTLineGetTrailingWhitespaceWidth(line))
                let a = max(ascent, lineAscent)
                let d = max(descent, lineDescent)
                laidOut.append(Line(line: line, origin: CGPoint(x: 0, y: y + a), width: lineWidth))
                y += max(fontLineHeight, a + d + leading)
                start += count
            }
        }
        if laidOut.isEmpty { y = fontLineHeight }

        let boxWidth = wrapWidth ?? (laidOut.map(\.width).max() ?? 0)
        var minX = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude
        for i in laidOut.indices {
            let offset: Double
            switch alignment {
            case .left: offset = 0
            case .center: offset = (boxWidth - laidOut[i].width) / 2
            case .right: offset = boxWidth - laidOut[i].width
            }
            laidOut[i].origin = CGPoint(x: origin.x + offset, y: origin.y + laidOut[i].origin.y)
            minX = min(minX, origin.x + offset)
            maxX = max(maxX, origin.x + offset + laidOut[i].width)
        }
        if laidOut.isEmpty || minX > maxX {
            let x: Double
            switch alignment {
            case .left: x = origin.x
            case .center: x = origin.x + boxWidth / 2
            case .right: x = origin.x + boxWidth
            }
            minX = x
            maxX = x
        }
        self.lines = laidOut
        self.lineHeight = fontLineHeight
        self.usedRect = CGRect(x: minX, y: origin.y, width: maxX - minX, height: y)
    }

    /// The height `frame.height` should have for `shape` (laid-out text,
    /// excluding box padding).
    public static func fittedHeight(for shape: TextShape) -> Double {
        TextLayout(shape: shape).usedRect.height
    }

    // MARK: Drawing

    /// Fills the glyphs with `color` (y-down context).
    func fill(in context: CGContext, color: RGBAColor) {
        context.saveGState()
        context.setTextDrawingMode(.fill)
        context.setFillColor(color.cgColor)
        drawLines(in: context)
        context.restoreGState()
    }

    /// Strokes the glyph outlines (round joins) with `color`, line width `width`.
    func stroke(in context: CGContext, color: RGBAColor, width: Double) {
        context.saveGState()
        context.setTextDrawingMode(.stroke)
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineJoin(.round)
        context.setLineCap(.round)
        drawLines(in: context)
        context.restoreGState()
    }

    private func drawLines(in context: CGContext) {
        for line in lines {
            context.saveGState()
            context.translateBy(x: line.origin.x, y: line.origin.y)
            context.scaleBy(x: 1, y: -1)
            context.textPosition = .zero
            CTLineDraw(line.line, context)
            context.restoreGState()
        }
    }
}
