import CoreGraphics

/// Pure geometry for cropping the notch strip out of fullscreen captures
/// (plan §4.6). The app reads `NSScreen.safeAreaInsets.top` and
/// `auxiliaryTopLeftArea` / `auxiliaryTopRightArea`; this type only does math.
///
/// Measured on a 14" MacBook Pro (macOS 27): `safeAreaInsets.top = 37.5`,
/// both auxiliary areas 37.5 pt high, menu bar window 38 pt, scale 2 → 75 px.
public enum NotchMath {
    /// A display has a camera housing when AppKit reports a top safe-area
    /// inset, or reports the two menu-bar areas beside the housing.
    public static func hasNotch(safeAreaTopInset: CGFloat, auxiliaryTopLeft: CGRect?, auxiliaryTopRight: CGRect?) -> Bool {
        if safeAreaTopInset > 0 { return true }
        guard let left = auxiliaryTopLeft, let right = auxiliaryTopRight else { return false }
        return left.height > 0 && right.height > 0
    }

    /// Points to cut from the top of a fullscreen capture of this display: the
    /// strip beside the notch (the larger of the safe-area inset and the
    /// auxiliary areas' height), rounded **up** to whole device pixels so no
    /// half-covered pixel row of the menu bar survives. `0` when the display
    /// has no notch or the strip would swallow the whole display.
    public static func topCropInset(
        safeAreaTopInset: CGFloat,
        auxiliaryTopHeight: CGFloat?,
        displayHeight: CGFloat,
        scale: CGFloat
    ) -> CGFloat {
        let strip = max(safeAreaTopInset, auxiliaryTopHeight ?? 0, 0)
        guard strip > 0, scale > 0, displayHeight > 0 else { return 0 }
        // Tolerate float noise (e.g. 37.50000001 × 2) before rounding up.
        let pixels = (strip * scale - 0.001).rounded(.up)
        let inset = pixels / scale
        return inset < displayHeight ? inset : 0
    }

    /// The display frame (Quartz global points) minus the top `inset`.
    public static func croppedFrame(_ displayFrame: GlobalRect, topInset inset: CGFloat) -> GlobalRect {
        let clamped = min(max(inset, 0), displayFrame.height)
        return GlobalRect(
            x: displayFrame.minX, y: displayFrame.minY + clamped,
            width: displayFrame.width, height: displayFrame.height - clamped
        )
    }
}
