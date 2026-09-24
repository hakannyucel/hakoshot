import CoreGraphics
import Foundation

/// Pure geometry for the card stack (plan §4.12, §5.4). AppKit screen coordinates
/// (origin bottom-left, y up). Kept free of AppKit so it is unit-testable.
nonisolated enum QuickAccessLayout {
    /// Transparent margin around each card inside its panel so the shadow isn't clipped.
    static var shadowMargin: CGFloat { Tokens.QuickAccess.shadowMargin }
    /// Card height relative to width: very wide / tall captures are cropped (aspect fill).
    static var minAspect: CGFloat { Tokens.QuickAccess.minAspect }
    static var maxAspect: CGFloat { Tokens.QuickAccess.maxAspect }

    /// Card size in points for an image of `imageSize` at `width`.
    static func cardSize(imageSize: CGSize, width: CGFloat) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGSize(width: width, height: (width * 0.625).rounded())
        }
        let aspect = min(max(imageSize.height / imageSize.width, minAspect), maxAspect)
        return CGSize(width: width, height: (width * aspect).rounded())
    }

    /// Card frames for a stack anchored in a bottom corner of `visibleFrame`.
    ///
    /// `sizes` is ordered oldest → newest. The oldest card sits in the corner and each
    /// newer card is placed above the previous one, so the newest is on top (plan §4.12)
    /// and existing cards never move when a new one arrives.
    static func cardFrames(
        sizes: [CGSize],
        in visibleFrame: CGRect,
        position: QuickAccessPosition,
        inset: CGFloat,
        gap: CGFloat
    ) -> [CGRect] {
        var frames: [CGRect] = []
        var y = visibleFrame.minY + inset
        for size in sizes {
            let x: CGFloat = switch position {
            case .left: visibleFrame.minX + inset
            case .right: visibleFrame.maxX - inset - size.width
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            y += size.height + gap
        }
        return frames
    }

    /// Off-screen start/end frame for the slide-in/out animation: same y, pushed past
    /// the screen edge the stack is anchored to.
    static func offscreenFrame(for frame: CGRect, in visibleFrame: CGRect, position: QuickAccessPosition) -> CGRect {
        var result = frame
        switch position {
        case .left: result.origin.x = visibleFrame.minX - frame.width - shadowMargin
        case .right: result.origin.x = visibleFrame.maxX + shadowMargin
        }
        return result
    }

    /// Panel frame for a card frame (adds the shadow margin on all sides).
    static func panelFrame(forCard frame: CGRect) -> CGRect {
        frame.insetBy(dx: -shadowMargin, dy: -shadowMargin)
    }
}
