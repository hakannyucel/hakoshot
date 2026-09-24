import AppKit
import QuartzCore

/// Full-screen crosshair that follows the cursor before a drag: four thin line
/// segments that stop at a small empty circle around the hot spot (UI report §1).
/// Plain rect layers + one fixed-size circle, so a move only changes frames.
final class CrosshairLayer {
    let layer = CALayer()
    private let leftLine = CALayer()
    private let rightLine = CALayer()
    private let upperLine = CALayer()
    private let lowerLine = CALayer()
    private let circle = CAShapeLayer()

    init() {
        for line in [leftLine, rightLine, upperLine, lowerLine] {
            line.backgroundColor = Tokens.Overlay.crosshairColor.cgColor
            layer.addSublayer(line)
        }
        let diameter = Tokens.Overlay.crosshairCircleDiameter
        circle.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        circle.path = CGPath(ellipseIn: circle.bounds.insetBy(dx: Tokens.Overlay.crosshairLineWidth / 2, dy: Tokens.Overlay.crosshairLineWidth / 2), transform: nil)
        circle.fillColor = nil
        circle.strokeColor = Tokens.Overlay.crosshairColor.cgColor
        circle.lineWidth = Tokens.Overlay.crosshairLineWidth
        layer.addSublayer(circle)
        OverlayLayerActions.disable([layer, leftLine, rightLine, upperLine, lowerLine, circle])
        layer.isHidden = true
    }

    /// Moves the crosshair to `point` (view coordinates) or hides it (`nil`).
    /// `scale` snaps the lines to the device pixel grid so they stay crisp.
    func update(center point: CGPoint?, scale: CGFloat) {
        guard let point else {
            layer.isHidden = true
            return
        }
        layer.isHidden = false
        let s = max(scale, 1)
        let x = (point.x * s).rounded(.down) / s
        let y = (point.y * s).rounded(.down) / s
        let full = layer.bounds
        let width = Tokens.Overlay.crosshairLineWidth
        let gap = Tokens.Overlay.crosshairCircleDiameter / 2

        leftLine.frame = CGRect(x: full.minX, y: y, width: max(x - gap - full.minX, 0), height: width)
        rightLine.frame = CGRect(x: x + gap, y: y, width: max(full.maxX - x - gap, 0), height: width)
        lowerLine.frame = CGRect(x: x, y: full.minY, width: width, height: max(y - gap - full.minY, 0))
        upperLine.frame = CGRect(x: x, y: y + gap, width: width, height: max(full.maxY - y - gap, 0))
        circle.position = CGPoint(x: x + width / 2, y: y + width / 2)
    }
}
