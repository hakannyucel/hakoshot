import AppKit
import HakoKit
import QuartzCore

/// The 8 resize handles of an editable selection (All-In-One / scrolling,
/// plan §4.14): white dots with a thin dark ring and a soft shadow on the
/// selection's corners and edge midpoints. Edge handles are hidden when the
/// selection is too small to tell them apart from the corners.
final class SelectionHandlesLayer {
    let layer = CALayer()
    private var dots: [SelectionHandle: CALayer] = [:]

    private typealias T = Tokens.Overlay

    init() {
        let d = T.handleDiameter
        for handle in SelectionHandle.allCases {
            let dot = CALayer()
            dot.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            dot.cornerRadius = d / 2
            dot.backgroundColor = T.handleFill.cgColor
            dot.borderColor = T.handleBorder.cgColor
            dot.borderWidth = T.handleBorderWidth
            dot.shadowColor = NSColor.black.cgColor
            dot.shadowOpacity = Float(T.handleShadow.opacity)
            dot.shadowRadius = T.handleShadow.radius
            dot.shadowOffset = CGSize(width: 0, height: -T.handleShadow.y)
            dot.shadowPath = CGPath(ellipseIn: dot.bounds, transform: nil)
            layer.addSublayer(dot)
            dots[handle] = dot
        }
        OverlayLayerActions.disable([layer] + Array(dots.values))
        layer.isHidden = true
    }

    /// `selection` in view coordinates (AppKit, bottom-left origin), or `nil` to hide.
    func update(selection: CGRect?, scale: CGFloat) {
        guard let rect = selection else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        let showEdges = min(rect.width, rect.height) >= T.handleDiameter * 4
        for (handle, dot) in dots {
            dot.contentsScale = scale
            dot.isHidden = !handle.isCorner && !showEdges
            dot.position = Self.center(of: handle, on: rect)
        }
    }

    /// Handle centers in AppKit orientation (`top` = `maxY`).
    private static func center(of handle: SelectionHandle, on rect: CGRect) -> CGPoint {
        let edges = handle.edges
        let x = edges.contains(.minX) ? rect.minX : edges.contains(.maxX) ? rect.maxX : rect.midX
        let y = edges.contains(.minY) ? rect.maxY : edges.contains(.maxY) ? rect.minY : rect.midY
        return CGPoint(x: x, y: y)
    }
}
