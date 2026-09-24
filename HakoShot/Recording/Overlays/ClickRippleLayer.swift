import AppKit
import HakoKit
import QuartzCore

/// One click ring (plan §4.9), driven by `ClickEffectModel` so the live
/// overlay and the Studio render share the curve: radius 18 → 30 pt ease-out,
/// opacity 1 → 0 over 0.35 s; `.filled` adds a translucent disc; right /
/// other clicks add an inner ring.
///
/// `layer` is a zero-size container positioned at the click; the ring, disc
/// and inner ring are centered on its origin. Rings are plain `CALayer`s
/// with a border (radius = ring center line), which render crisply both on
/// screen and through `CALayer.render(in:)` for snapshots.
@MainActor
final class ClickRippleLayer {
    let layer = CALayer()
    let model: ClickEffectModel
    let button: RecordingMouseButton
    /// `CACurrentMediaTime()` at the click.
    let startTime: CFTimeInterval

    private let ring = CALayer()
    private let fill = CALayer()
    private let inner = CALayer()

    /// `point` is in the overlay's y-down, display-local points.
    init(point: CGPoint, button: RecordingMouseButton, model: ClickEffectModel, color: NSColor,
         startTime: CFTimeInterval = CACurrentMediaTime()) {
        self.model = model
        self.button = button
        self.startTime = startTime

        let cgColor = color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor
        layer.bounds = .zero
        layer.position = point
        fill.backgroundColor = cgColor
        ring.borderColor = cgColor
        inner.borderColor = cgColor
        for sublayer in [fill, ring, inner] {
            sublayer.position = .zero
            layer.addSublayer(sublayer)
        }
        OverlayLayerActions.disable([layer, fill, ring, inner])
        for sublayer in [fill, ring, inner] {
            sublayer.actions?["borderWidth"] = NSNull()
            sublayer.actions?["cornerRadius"] = NSNull()
            sublayer.actions?["backgroundColor"] = NSNull()
        }
        apply(at: 0)
    }

    /// `CACurrentMediaTime()` after which the ring is invisible.
    var endTime: CFTimeInterval { startTime + model.duration }

    /// Static state `t` seconds after the click (no animations): used for
    /// snapshots and as the model values under the live animation.
    func apply(at t: Double) {
        for sublayer in [fill, ring, inner] { sublayer.removeAllAnimations() }
        let frame = model.unclampedFrame(at: t, button: button)
        set(frame)
    }

    /// Runs the whole effect on the render server (keyframes sampled from the
    /// model); the model values end invisible, so nothing lingers.
    func animate() {
        let samples = model.samples(count: 24, button: button)
        set(samples.last ?? model.unclampedFrame(at: model.duration, button: button))
        let keyTimes = samples.indices.map { NSNumber(value: Double($0) / Double(max(samples.count - 1, 1))) }

        func add(_ target: CALayer, _ keyPath: String, _ values: [Any]) {
            let animation = CAKeyframeAnimation(keyPath: keyPath)
            animation.values = values
            animation.keyTimes = keyTimes
            animation.duration = model.duration
            animation.calculationMode = .linear
            animation.isRemovedOnCompletion = true
            target.add(animation, forKey: keyPath)
        }

        let lineWidth = model.lineWidth
        add(ring, "bounds", samples.map { NSValue(rect: Self.ringBounds(radius: $0.radius, lineWidth: lineWidth)) })
        add(ring, "cornerRadius", samples.map { $0.radius + lineWidth / 2 })
        add(ring, "opacity", samples.map { Float($0.strokeAlpha) })
        if model.style == .filled {
            add(fill, "bounds", samples.map { NSValue(rect: Self.ringBounds(radius: $0.radius, lineWidth: lineWidth)) })
            add(fill, "cornerRadius", samples.map { $0.radius + lineWidth / 2 })
            add(fill, "opacity", samples.map { Float($0.fillAlpha) })
        }
        if button != .left {
            add(inner, "bounds", samples.map { NSValue(rect: Self.ringBounds(radius: $0.secondaryRadius ?? 0, lineWidth: lineWidth)) })
            add(inner, "cornerRadius", samples.map { ($0.secondaryRadius ?? 0) + lineWidth / 2 })
            add(inner, "opacity", samples.map { Float($0.strokeAlpha) })
        }
    }

    // MARK: Private

    private func set(_ frame: ClickEffectFrame) {
        let outer = Self.ringBounds(radius: frame.radius, lineWidth: frame.lineWidth)
        ring.bounds = outer
        ring.cornerRadius = outer.width / 2
        ring.borderWidth = frame.lineWidth
        ring.opacity = Float(frame.strokeAlpha)

        fill.bounds = outer
        fill.cornerRadius = outer.width / 2
        fill.opacity = Float(frame.fillAlpha)
        fill.isHidden = model.style != .filled

        if let secondary = frame.secondaryRadius {
            let innerBounds = Self.ringBounds(radius: secondary, lineWidth: frame.lineWidth)
            inner.bounds = innerBounds
            inner.cornerRadius = innerBounds.width / 2
            inner.borderWidth = frame.lineWidth
            inner.opacity = Float(frame.strokeAlpha)
            inner.isHidden = false
        } else {
            inner.isHidden = true
        }
    }

    /// A border drawn inside the bounds, so the bounds reach half a line past
    /// the center-line radius.
    static func ringBounds(radius: Double, lineWidth: Double) -> CGRect {
        let side = max(2 * radius + lineWidth, 0)
        return CGRect(x: 0, y: 0, width: side, height: side)
    }
}
