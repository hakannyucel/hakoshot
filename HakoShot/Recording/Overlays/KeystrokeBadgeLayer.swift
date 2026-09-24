import AppKit
import HakoKit
import QuartzCore

/// The keystroke badge (plan §4.9): a dark (or light) capsule with white
/// glyphs, "⇧⌘F". Layout comes from `KeystrokeBadgeLayout`, fades and the
/// "⌘Z ×3" repeat pulse from `KeystrokeBadgeTiming` / `KeystrokeRepeatMerger`
/// — the same models the Studio render uses.
///
/// Lives in the overlay's y-down, display-local coordinate space.
@MainActor
final class KeystrokeBadgeLayer {
    /// The capsule; the text is its sublayer.
    let layer = CALayer()
    private let textLayer = CATextLayer()

    private(set) var metrics: KeystrokeBadgeMetrics
    private(set) var placement: KeystrokeBadgePlacement
    private(set) var timing: KeystrokeBadgeTiming
    private var textColor: NSColor
    private var merger: KeystrokeRepeatMerger
    /// y-down rect the badge is placed in (display, recorded area or window).
    var container: CGRect {
        didSet { if let entry = merger.current { layout(label: entry.label) } }
    }

    init(metrics: KeystrokeBadgeMetrics, placement: KeystrokeBadgePlacement, timing: KeystrokeBadgeTiming,
         fill: NSColor, text: NSColor, container: CGRect, contentsScale: CGFloat) {
        self.metrics = metrics
        self.placement = placement
        self.timing = timing
        self.textColor = text
        self.merger = KeystrokeRepeatMerger(timing: timing)
        self.container = container

        layer.backgroundColor = fill.cgColor
        layer.opacity = 0
        layer.addSublayer(textLayer)
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.isWrapped = false
        textLayer.contentsScale = contentsScale
        OverlayLayerActions.disable([layer, textLayer])
        layer.actions?["transform"] = NSNull()
        layer.actions?["cornerRadius"] = NSNull()
        layer.actions?["backgroundColor"] = NSNull()
        textLayer.actions?["foregroundColor"] = NSNull()
    }

    /// The entry on screen (`nil` before the first key or after `clear()`).
    var currentEntry: KeystrokeBadgeEntry? { merger.current }

    /// Current label ("⌘Z ×3"); `nil` when nothing is shown.
    var label: String? { merger.current?.label }

    func update(metrics: KeystrokeBadgeMetrics, placement: KeystrokeBadgePlacement, fill: NSColor, text: NSColor) {
        self.metrics = metrics
        self.placement = placement
        self.textColor = text
        layer.backgroundColor = fill.cgColor
        if let entry = merger.current { layout(label: entry.label) }
    }

    /// Shows `text` (already formatted and filtered) at `time`
    /// (`CACurrentMediaTime()` clock), merging repeats.
    func show(_ text: String, at time: CFTimeInterval = CACurrentMediaTime()) {
        let entry = merger.add(text, at: time)
        merger.trimHistory()
        layout(label: entry.label)
        animate(entry, from: time)
    }

    /// Static state at `time` (snapshots): no animations.
    func apply(at time: CFTimeInterval) {
        layer.removeAllAnimations()
        guard let entry = merger.current, let asOf = entry.asOf(time) else {
            layer.opacity = 0
            return
        }
        layout(label: asOf.label)
        layer.opacity = Float(timing.alpha(for: asOf, at: time))
        layer.transform = CATransform3DMakeScale(timing.scale(for: asOf, at: time), timing.scale(for: asOf, at: time), 1)
    }

    /// Hides the badge immediately and forgets the current run.
    func clear() {
        layer.removeAllAnimations()
        layer.opacity = 0
        layer.transform = CATransform3DIdentity
        merger.reset()
    }

    /// When the current badge is fully gone (`nil` = nothing showing).
    var endTime: CFTimeInterval? { merger.current.map { timing.endTime(of: $0) } }

    // MARK: Private

    private func layout(label: String) {
        let width = KeystrokeBadgeLayout.textWidth(label, fontSize: metrics.fontSize)
        let frame = KeystrokeBadgeLayout.frame(textWidth: width, metrics: metrics, placement: placement,
                                               in: container, yDown: true)
        // Keep any running scale transform: set bounds/position, not frame.
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.position = CGPoint(x: frame.midX, y: frame.midY)
        layer.cornerRadius = metrics.cornerRadius

        let font = KeystrokeBadgeLayout.font(size: metrics.fontSize)
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        let textWidth = max(frame.width - 2 * metrics.paddingH, 0)
        textLayer.frame = CGRect(x: (frame.width - textWidth) / 2, y: (frame.height - lineHeight) / 2,
                                 width: textWidth, height: lineHeight)
        textLayer.string = NSAttributedString(string: label, attributes: [
            .font: font as NSFont,
            .foregroundColor: textColor,
        ])
    }

    /// Opacity keyframes at the piecewise-linear breakpoints of
    /// `KeystrokeBadgeTiming.alpha` from `now` to the end; the scale pulse on
    /// repeats. Model values end invisible.
    private func animate(_ entry: KeystrokeBadgeEntry, from now: CFTimeInterval) {
        let end = timing.endTime(of: entry)
        let breakpoints = [now, entry.fadeInStart + timing.fadeIn, entry.lastTime + timing.hold, end]
            .filter { $0 >= now && $0 <= end }
        let times = Array(Set(breakpoints)).sorted()
        let total = max(end - now, 0.001)

        layer.removeAnimation(forKey: "opacity")
        layer.opacity = 0
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = times.map { Float(timing.alpha(for: entry, at: $0)) }
        fade.keyTimes = times.map { NSNumber(value: ($0 - now) / total) }
        fade.duration = total
        fade.calculationMode = .linear
        layer.add(fade, forKey: "opacity")

        layer.removeAnimation(forKey: "transform.scale")
        layer.transform = CATransform3DIdentity
        guard entry.count > 1, timing.pulseDuration > 0 else { return }
        let steps = 10
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = (0...steps).map { timing.pulse(sinceRepeat: timing.pulseDuration * Double($0) / Double(steps) * 0.999) }
        pulse.keyTimes = (0...steps).map { NSNumber(value: Double($0) / Double(steps)) }
        pulse.duration = timing.pulseDuration
        pulse.calculationMode = .linear
        layer.add(pulse, forKey: "transform.scale")
    }
}
