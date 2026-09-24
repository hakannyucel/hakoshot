import CoreGraphics
import CoreText
import Foundation

/// Keystroke badge position (plan §4.9). Same raw values as the app's
/// `KeystrokeBadgePosition` and `StudioKeystrokeSettings.position`.
public enum KeystrokeBadgePlacement: String, Sendable, Hashable, Codable, CaseIterable {
    case bottomCenter, bottomLeft, bottomRight, topCenter
}

// MARK: - Timing

/// Badge fade in / hold / fade out and the repeat pulse (plan §4.9, §5.2:
/// 200 ms in, held 1.2 s after the last key, 200 ms out; "×N" repeats pulse
/// 1.1 → 1). Values match `Tokens.Recording.keystroke*`.
public struct KeystrokeBadgeTiming: Sendable, Hashable {
    public var fadeIn: Double
    public var hold: Double
    public var fadeOut: Double
    public var pulseScale: Double
    /// 1.1 → 1 over this long after each repeat (ease-out cubic).
    public var pulseDuration: Double

    public static let standard = KeystrokeBadgeTiming()

    public init(fadeIn: Double = 0.2, hold: Double = 1.2, fadeOut: Double = 0.2, pulseScale: Double = 1.1, pulseDuration: Double = 0.2) {
        self.fadeIn = max(fadeIn, 0)
        self.hold = max(hold, 0)
        self.fadeOut = max(fadeOut, 0)
        self.pulseScale = pulseScale
        self.pulseDuration = max(pulseDuration, 0)
    }

    /// Alpha for a badge that started fading in at `fadeInStart` and whose
    /// last key came at `lastKey`: linear in, full until `lastKey + hold`,
    /// linear out; `0` before and after.
    public func alpha(fadeInStart: Double, lastKey: Double, at t: Double) -> Double {
        // `ε` absorbs float noise at the edges (e.g. 1 + 1.2 + 0.2 ≠ 2.4).
        let ε = 1e-9
        guard t.isFinite, t >= fadeInStart - ε else { return 0 }
        let fadeInAlpha = fadeIn > 0 && t < fadeInStart + fadeIn - ε ? max((t - fadeInStart) / fadeIn, 0) : 1
        let outStart = lastKey + hold
        let fadeOutAlpha: Double
        if t < outStart + ε {
            fadeOutAlpha = 1
        } else if fadeOut > 0, t < outStart + fadeOut - ε {
            fadeOutAlpha = 1 - (t - outStart) / fadeOut
        } else {
            fadeOutAlpha = 0
        }
        return max(0, min(fadeInAlpha, fadeOutAlpha))
    }

    public func alpha(for entry: KeystrokeBadgeEntry, at t: Double) -> Double {
        alpha(fadeInStart: entry.fadeInStart, lastKey: entry.lastTime, at: t)
    }

    /// When the entry is fully gone.
    public func endTime(of entry: KeystrokeBadgeEntry) -> Double {
        entry.lastTime + hold + fadeOut
    }

    /// Repeat pulse scale `t` seconds after a repeated press (`1` when the
    /// press wasn't a repeat or the pulse is over).
    public func pulse(sinceRepeat t: Double) -> Double {
        guard t.isFinite, t >= 0, pulseDuration > 0, t < pulseDuration else { return 1 }
        let eased = StudioEasing.easeOutCubic.apply(t / pulseDuration)
        return pulseScale + (1 - pulseScale) * eased
    }

    /// Scale of `entry` at `t` (pulses only once `count > 1`).
    public func scale(for entry: KeystrokeBadgeEntry, at t: Double) -> Double {
        entry.count > 1 ? pulse(sinceRepeat: t - entry.lastTime) : 1
    }
}

// MARK: - Metrics

/// Badge geometry in reference points (plan §4.9: 44 pt tall at Medium,
/// 64 pt from the bottom edge). Values match `Tokens.Recording`.
public struct KeystrokeBadgeMetrics: Sendable, Hashable {
    public var height: Double
    public var paddingH: Double
    /// Distance from the container's bottom (or top for `.topCenter`) edge.
    public var edgeInset: Double
    /// Distance from the side edge for `.bottomLeft` / `.bottomRight`.
    public var sideInset: Double
    public var fontSize: Double

    public var cornerRadius: Double { height / 2 }

    public init(height: Double, paddingH: Double = 16, edgeInset: Double = 64, sideInset: Double = 64, fontSize: Double? = nil) {
        self.height = height
        self.paddingH = paddingH
        self.edgeInset = edgeInset
        self.sideInset = sideInset
        self.fontSize = fontSize ?? Self.fontSize(forHeight: height)
    }

    /// Glyph size relative to the pill height.
    public static let fontSizeFraction = 0.45

    public static func fontSize(forHeight height: Double) -> Double { (height * fontSizeFraction).rounded() }

    /// Matches `Tokens.Recording.keystrokeBadgeHeight`.
    public static func height(_ size: RecordingOverlaySize) -> Double {
        switch size {
        case .small: 34
        case .medium: 44
        case .large: 56
        }
    }

    public static func standard(_ size: RecordingOverlaySize) -> KeystrokeBadgeMetrics {
        KeystrokeBadgeMetrics(height: height(size))
    }

    /// Every length × `factor` (Studio: reference points → canvas pixels).
    public func scaled(by factor: Double) -> KeystrokeBadgeMetrics {
        KeystrokeBadgeMetrics(height: height * factor, paddingH: paddingH * factor, edgeInset: edgeInset * factor,
                              sideInset: sideInset * factor, fontSize: fontSize * factor)
    }
}

// MARK: - Layout

/// Badge size and position for a text (plan §4.9). Pure geometry; the live
/// overlay and the Studio render share it.
public enum KeystrokeBadgeLayout {
    /// The badge font (semibold system UI font). The app renders with this
    /// same `CTFont` so measured and drawn widths agree.
    public static func font(size: Double) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let traits: [CFString: Any] = [kCTFontWeightTrait: 0.3] // ≈ semibold
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(
            CTFontCopyFontDescriptor(base),
            [kCTFontTraitsAttribute: traits] as CFDictionary
        )
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    /// Typographic width of `text` in the badge font.
    public static func textWidth(_ text: String, fontSize: Double) -> Double {
        let attributed = CFAttributedStringCreate(
            nil, text as CFString,
            [kCTFontAttributeName: font(size: fontSize)] as CFDictionary
        )
        guard let attributed else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        return Double(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    /// Pill size: text + padding, never narrower than a circle, never wider
    /// than `maxWidth`.
    public static func badgeSize(textWidth: Double, metrics: KeystrokeBadgeMetrics, maxWidth: Double = .infinity) -> CGSize {
        let width = max(metrics.height, (textWidth + 2 * metrics.paddingH).rounded(.up))
        return CGSize(width: min(width, max(maxWidth, metrics.height)), height: metrics.height)
    }

    /// Badge frame inside `container` (the recorded display / area / window,
    /// or the Studio content rect). `yDown`: `container` uses a top-left
    /// origin (Quartz, Studio canvas, flipped layers); otherwise bottom-left.
    /// Insets shrink so the badge stays inside small containers.
    public static func frame(textWidth: Double, metrics: KeystrokeBadgeMetrics, placement: KeystrokeBadgePlacement,
                             in container: CGRect, yDown: Bool = true) -> CGRect {
        let size = badgeSize(textWidth: textWidth, metrics: metrics, maxWidth: container.width)
        let w = Double(size.width), h = Double(size.height)
        let cw = Double(container.width), ch = Double(container.height)
        let edge = min(metrics.edgeInset, max((ch - h) / 2, 0))
        let side = min(metrics.sideInset, max((cw - w) / 2, 0))

        let x: Double
        switch placement {
        case .bottomCenter, .topCenter: x = (cw - w) / 2
        case .bottomLeft: x = side
        case .bottomRight: x = cw - side - w
        }
        // Distance from the top in a y-down frame.
        let fromTop = placement == .topCenter ? edge : ch - edge - h
        let y = yDown ? fromTop : ch - fromTop - h
        return CGRect(x: Double(container.minX) + x, y: Double(container.minY) + y, width: w, height: h)
    }

    /// Convenience: measures `text` with `metrics.fontSize`.
    public static func frame(text: String, metrics: KeystrokeBadgeMetrics, placement: KeystrokeBadgePlacement,
                             in container: CGRect, yDown: Bool = true) -> CGRect {
        frame(textWidth: textWidth(text, fontSize: metrics.fontSize), metrics: metrics, placement: placement,
              in: container, yDown: yDown)
    }
}

// MARK: - Timeline (Studio / snapshots)

/// What the badge shows at one instant.
public struct KeystrokeBadgeFrame: Sendable, Hashable {
    /// "⌘Z ×3".
    public var label: String
    public var alpha: Double
    public var scale: Double
}

/// Badge state at any time from merged entries (Studio export draws from
/// metadata; the live layer uses the same timing).
public enum KeystrokeBadgeTimeline {
    /// The newest entry started at or before `t`, if it's still visible.
    public static func frame(at t: Double, entries: [KeystrokeBadgeEntry], timing: KeystrokeBadgeTiming = .standard) -> KeystrokeBadgeFrame? {
        // Repeats after `t` haven't happened yet.
        guard let entry = entries.last(where: { $0.firstTime <= t })?.asOf(t) else { return nil }
        let alpha = timing.alpha(for: entry, at: t)
        guard alpha > 0 else { return nil }
        return KeystrokeBadgeFrame(label: entry.label, alpha: alpha, scale: timing.scale(for: entry, at: t))
    }
}
