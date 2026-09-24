import AppKit
import QuartzCore

/// Dimmed backdrop with the selection cut out, plus the selection frame.
///
/// The dim is four plain rect layers around the selection (not a masked shape
/// path), so a mouse move only changes four frames — cheap at 120 Hz.
/// Coordinates are the owning view's (AppKit, bottom-left origin).
///
/// Owns its `layer` instead of subclassing `CALayer` (CALayer's initializers are
/// nonisolated, which clashes with the app's MainActor default isolation).
final class SelectionBackdropLayer {
    let layer = CALayer()
    private let top = CALayer()
    private let bottom = CALayer()
    private let left = CALayer()
    private let right = CALayer()
    private let innerFrame = CALayer()
    private let outerFrame = CALayer()

    init() {
        for dim in [top, bottom, left, right] {
            dim.backgroundColor = Tokens.Overlay.dimColor
            layer.addSublayer(dim)
        }
        outerFrame.borderColor = Tokens.Overlay.frameOuterColor.cgColor
        outerFrame.borderWidth = Tokens.Overlay.frameLineWidth
        innerFrame.borderColor = Tokens.Overlay.frameInnerColor.cgColor
        innerFrame.borderWidth = Tokens.Overlay.frameLineWidth
        layer.addSublayer(outerFrame)
        layer.addSublayer(innerFrame)
        OverlayLayerActions.disable([layer, top, bottom, left, right, innerFrame, outerFrame])
        update(.clear)
    }

    enum State {
        /// Nothing dimmed (before a drag starts).
        case clear
        /// Whole display dimmed (a selection exists on another display).
        case dimmedFully
        /// Everything but `selection` dimmed; `selection` is framed.
        case selection(CGRect)
    }

    /// Call inside a transaction with actions disabled.
    func update(_ state: State) {
        let full = layer.bounds
        switch state {
        case .clear:
            [top, bottom, left, right, innerFrame, outerFrame].forEach { $0.isHidden = true }
        case .dimmedFully:
            top.frame = full
            top.isHidden = false
            [bottom, left, right, innerFrame, outerFrame].forEach { $0.isHidden = true }
        case .selection(let sel):
            // AppKit coordinates: "top" has the larger y.
            top.frame = CGRect(x: full.minX, y: sel.maxY, width: full.width, height: max(full.maxY - sel.maxY, 0))
            bottom.frame = CGRect(x: full.minX, y: full.minY, width: full.width, height: max(sel.minY - full.minY, 0))
            left.frame = CGRect(x: full.minX, y: sel.minY, width: max(sel.minX - full.minX, 0), height: sel.height)
            right.frame = CGRect(x: sel.maxX, y: sel.minY, width: max(full.maxX - sel.maxX, 0), height: sel.height)
            // Frame lines sit outside the selection so no selected pixel is covered.
            let line = Tokens.Overlay.frameLineWidth
            innerFrame.frame = sel.insetBy(dx: -line, dy: -line)
            outerFrame.frame = sel.insetBy(dx: -2 * line, dy: -2 * line)
            [top, bottom, left, right, innerFrame, outerFrame].forEach { $0.isHidden = false }
        }
    }
}

enum OverlayLayerActions {
    /// Removes implicit animations so layer changes land on the next frame.
    static func disable(_ layers: [CALayer]) {
        let none: [String: any CAAction] = [
            "position": NSNull(), "bounds": NSNull(), "frame": NSNull(), "hidden": NSNull(),
            "contents": NSNull(), "path": NSNull(), "opacity": NSNull(), "sublayers": NSNull(),
            "string": NSNull(),
        ]
        for layer in layers {
            layer.actions = none
        }
    }
}
