import Foundation

/// Small / Medium / Large for the recording overlays (click ring, keystroke
/// badge). Same raw values as the app's `RecordingElementSize`.
public enum RecordingOverlaySize: String, Sendable, Hashable, Codable, CaseIterable {
    case small, medium, large
}

/// Click highlight style (plan §4.9). Same raw values as the app's
/// `ClickHighlightStyle`.
public enum ClickEffectStyle: String, Sendable, Hashable, Codable, CaseIterable {
    /// Thin ring, no fill (default, observed in CleanShot).
    case outline
    /// Translucent disc plus the ring.
    case filled
}

/// What a click effect looks like at one instant. Lengths are reference
/// points (multiply by the canvas' points → pixels factor when rendering).
public struct ClickEffectFrame: Sendable, Hashable {
    /// `0…1` through the effect.
    public var progress: Double
    /// Main ring radius (ring center line).
    public var radius: Double
    public var lineWidth: Double
    /// Overall opacity `0…1`.
    public var alpha: Double
    /// Ring stroke opacity (`alpha`).
    public var strokeAlpha: Double
    /// Disc fill opacity (`0` for `.outline`).
    public var fillAlpha: Double
    /// Right / other button: a second, inner ring at this radius (`nil` for
    /// the left button).
    public var secondaryRadius: Double?
}

/// Click ring curve shared by the live overlay (`ClickRippleLayer`) and the
/// Studio render (`StudioFrameState`), plan §4.9 / §5.2: radius 18 → 30 pt
/// with ease-out cubic over 0.35 s, opacity 1 → 0 linearly, 2 pt line.
/// Right clicks add an inner ring at `secondaryRingFraction` of the radius
/// (the same fraction as `StudioFrameRenderer.Options`).
public struct ClickEffectModel: Sendable, Hashable {
    public static let defaultDuration = 0.35
    public static let defaultStartRadius = 18.0
    public static let defaultEndRadius = 30.0
    public static let defaultLineWidth = 2.0
    /// `.filled` disc opacity at full alpha (matches `Tokens.Recording.clickFillOpacity`).
    public static let defaultFillOpacity = 0.35
    public static let secondaryRingFraction = 0.6
    public static let radiusEasing = StudioEasing.easeOutCubic

    /// Radius multiplier per size (matches `Tokens.Recording.clickScale`).
    public static func sizeScale(_ size: RecordingOverlaySize) -> Double {
        switch size {
        case .small: 0.75
        case .medium: 1
        case .large: 1.4
        }
    }

    /// Studio's click ring: outline, medium, animated.
    public static let standard = ClickEffectModel()

    public var style: ClickEffectStyle
    /// Radius multiplier (`sizeScale`). The line width is not scaled.
    public var scale: Double
    /// `false`: a static ring at the start radius, full opacity for the
    /// whole duration (settings "Animated" off).
    public var animated: Bool
    public var duration: Double
    public var startRadius: Double
    public var endRadius: Double
    public var lineWidth: Double
    public var fillOpacity: Double

    public init(
        style: ClickEffectStyle = .outline,
        scale: Double = 1,
        animated: Bool = true,
        duration: Double = ClickEffectModel.defaultDuration,
        startRadius: Double = ClickEffectModel.defaultStartRadius,
        endRadius: Double = ClickEffectModel.defaultEndRadius,
        lineWidth: Double = ClickEffectModel.defaultLineWidth,
        fillOpacity: Double = ClickEffectModel.defaultFillOpacity
    ) {
        self.style = style
        self.scale = scale
        self.animated = animated
        self.duration = max(duration, 0.001)
        self.startRadius = startRadius
        self.endRadius = endRadius
        self.lineWidth = lineWidth
        self.fillOpacity = fillOpacity
    }

    public init(style: ClickEffectStyle, size: RecordingOverlaySize, animated: Bool = true) {
        self.init(style: style, scale: Self.sizeScale(size), animated: animated)
    }

    /// Visible at `t` seconds after the mouse-down (`0 ≤ t < duration`).
    public func isActive(at t: Double) -> Bool {
        t.isFinite && t >= 0 && t < duration
    }

    /// `t / duration`, clamped to `0…1`.
    public func progress(at t: Double) -> Double {
        guard t.isFinite else { return 0 }
        return min(max(t / duration, 0), 1)
    }

    /// Ring radius (reference points, `scale` applied).
    public func radius(at t: Double) -> Double {
        guard animated else { return startRadius * scale }
        let eased = Self.radiusEasing.apply(progress(at: t))
        return (startRadius + (endRadius - startRadius) * eased) * scale
    }

    /// Overall opacity; `0` outside the effect.
    public func alpha(at t: Double) -> Double {
        guard isActive(at: t) else { return 0 }
        return animated ? 1 - progress(at: t) : 1
    }

    /// Full description at `t`, or `nil` when the effect isn't visible.
    public func frame(at t: Double, button: RecordingMouseButton = .left) -> ClickEffectFrame? {
        guard isActive(at: t) else { return nil }
        return unclampedFrame(at: t, button: button)
    }

    /// Like `frame(at:)` but never `nil` (clamped progress; alpha 0 at and
    /// after the end) — for building keyframe animations.
    public func unclampedFrame(at t: Double, button: RecordingMouseButton = .left) -> ClickEffectFrame {
        let r = radius(at: t)
        let a = t >= duration ? 0 : alpha(at: max(t, 0))
        return ClickEffectFrame(
            progress: progress(at: t),
            radius: r,
            lineWidth: lineWidth,
            alpha: a,
            strokeAlpha: a,
            fillAlpha: style == .filled ? a * fillOpacity : 0,
            secondaryRadius: button == .left ? nil : r * Self.secondaryRingFraction
        )
    }

    /// `count + 1` evenly spaced frames over `0…duration` (last one alpha 0),
    /// for `CAKeyframeAnimation` values.
    public func samples(count: Int = 24, button: RecordingMouseButton = .left) -> [ClickEffectFrame] {
        let n = max(count, 1)
        return (0...n).map { unclampedFrame(at: duration * Double($0) / Double(n), button: button) }
    }
}
