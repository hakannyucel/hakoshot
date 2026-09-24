import CoreGraphics
import CoreText
import Foundation

/// Keystroke badge for one Studio frame (plan §4.9, §4.19): the live
/// overlay's pill, placed inside the content card (not zoomed).
public struct StudioKeystrokeBadgeState: Sendable, Hashable {
    /// "⌘Z" or "⌘Z ×3".
    public var text: String
    /// `0…1` (fade in / out).
    public var alpha: Double
    /// Repeat pulse (1.1 → 1), around the frame's center.
    public var scale: Double
    /// Unscaled pill frame, canvas pixels, y down.
    public var frame: CGRect
    /// Glyph size, canvas pixels.
    public var fontSize: Double
    /// Light pill with dark glyphs; else dark pill with white glyphs.
    public var isLight: Bool

    public init(text: String, alpha: Double, scale: Double, frame: CGRect, fontSize: Double, isLight: Bool) {
        self.text = text
        self.alpha = alpha
        self.scale = scale
        self.frame = frame
        self.fontSize = fontSize
        self.isLight = isLight
    }
}

/// The recording's key events merged into badge runs once per filter
/// (`KeystrokeRepeatMerger`). Build it once per project / filter and pass
/// it to `StudioFrameState.make(…, keystrokes:)`; per-frame lookups are
/// then cheap.
public struct StudioKeystrokeEntries: Sendable, Hashable {
    public var filter: KeystrokeDisplayFilter
    /// Ascending by first press (source seconds).
    public var entries: [KeystrokeBadgeEntry]

    public init(filter: KeystrokeDisplayFilter, entries: [KeystrokeBadgeEntry]) {
        self.filter = filter
        self.entries = entries
    }

    /// Merges `metadata.keys` (auto-repeats skipped) through `filter`.
    public init(metadata: RecordingMetadata?, filter: KeystrokeDisplayFilter) {
        self.filter = filter
        entries = KeystrokeRepeatMerger.merge(events: metadata?.keys ?? [], filter: filter)
    }

    public static let empty = StudioKeystrokeEntries(filter: .allKeys, entries: [])

    /// Badge at source time `t`, or `nil` (hidden, no key on screen).
    /// `container` is the content rect; lengths scale by `lengthScale`.
    public func badge(at t: Double, settings: StudioKeystrokeSettings, container: CGRect,
                      lengthScale k: Double) -> StudioKeystrokeBadgeState? {
        guard settings.visible, !entries.isEmpty, container.width > 0, container.height > 0,
              let frame = KeystrokeBadgeTimeline.frame(at: t, entries: entries) else { return nil }
        let metrics = KeystrokeBadgeMetrics.standard(settings.badgeSize).scaled(by: k)
        let rect = KeystrokeBadgeLayout.frame(text: frame.label, metrics: metrics, placement: settings.placement,
                                              in: container, yDown: true)
        return StudioKeystrokeBadgeState(text: frame.label, alpha: frame.alpha, scale: frame.scale, frame: rect,
                                         fontSize: metrics.fontSize, isLight: settings.isLight)
    }
}

// MARK: - Pill image

/// Badge colors (`Tokens.Recording.keystroke*`). The dark fill is 85 %
/// instead of the live 72 %: Core Image blends in linear light, where 72 %
/// looks much lighter than the window server's gamma-space blend; 85 %
/// matches the live pill on mid tones.
public enum StudioKeystrokeBadgeColors {
    public static let darkFill = RGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 0.85)
    public static let darkText = RGBAColor.white
    public static let lightFill = RGBAColor(red: 0.96, green: 0.96, blue: 0.96, alpha: 0.96)
    public static let lightText = RGBAColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1)
}

enum StudioKeystrokeBadgeImage {
    /// The pill (fill + centered CoreText label) at `size` pixels.
    static func make(text: String, size: CGSize, fontSize: Double, isLight: Bool) -> CGImage? {
        let w = Int(size.width.rounded(.up)), h = Int(size.height.rounded(.up))
        guard w > 0, h > 0, let context = RenderSupport.makeBitmapContext(width: w, height: h) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        let fill = isLight ? StudioKeystrokeBadgeColors.lightFill : StudioKeystrokeBadgeColors.darkFill
        let ink = isLight ? StudioKeystrokeBadgeColors.lightText : StudioKeystrokeBadgeColors.darkText
        let radius = min(bounds.width, bounds.height) / 2
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.setFillColor(fill.cgColor)
        context.fillPath()

        let font = KeystrokeBadgeLayout.font(size: fontSize)
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: ink.cgColor]
        guard let attributed = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return context.makeImage()
        }
        var line = CTLineCreateWithAttributedString(attributed)
        // Horizontal padding scales with the pill (16 pt at the 44 pt Medium height).
        let available = max(bounds.width - 2 * bounds.height * 16 / 44, bounds.height / 2)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        var width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        if width > available, let token = CFAttributedStringCreate(nil, "…" as CFString, attributes as CFDictionary),
           let truncated = CTLineCreateTruncatedLine(line, Double(available), .end, CTLineCreateWithAttributedString(token)) {
            line = truncated
            width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        }
        // CG is y up here: baseline so the glyph box is vertically centered.
        let x = (bounds.width - width) / 2
        let y = (bounds.height - (ascent + descent)) / 2 + descent
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
        return context.makeImage()
    }
}
