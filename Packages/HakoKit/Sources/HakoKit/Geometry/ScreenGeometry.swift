import CoreGraphics

/// Converts between AppKit's screen space (bottom-left origin, per `NSScreen`)
/// and Quartz global space (top-left origin at the main display's top-left
/// corner) — see plan §3.2 and §4.7. All conversions go through here so `y`
/// is never flipped by hand elsewhere.
public enum ScreenGeometry {
    /// Converts a rect from AppKit global space into Quartz global space.
    /// Returns `nil` if `layout` has no main display.
    public static func globalRect(fromAppKit rect: CGRect, layout: DisplayLayout) -> GlobalRect? {
        guard let main = layout.mainDisplay else { return nil }
        let mainHeight = main.appKitFrame.height
        let quartzY = mainHeight - (rect.origin.y + rect.height)
        return GlobalRect(x: rect.origin.x, y: quartzY, width: rect.width, height: rect.height)
    }

    /// Converts a rect from Quartz global space back into AppKit global space.
    /// Returns `nil` if `layout` has no main display.
    public static func appKitRect(fromGlobal rect: GlobalRect, layout: DisplayLayout) -> CGRect? {
        guard let main = layout.mainDisplay else { return nil }
        let mainHeight = main.appKitFrame.height
        let appKitY = mainHeight - (rect.origin.y + rect.size.height)
        return CGRect(x: rect.origin.x, y: appKitY, width: rect.size.width, height: rect.size.height)
    }

    /// A display's own frame, expressed in Quartz global space.
    public static func globalFrame(of display: DisplayDescriptor, layout: DisplayLayout) -> GlobalRect? {
        globalRect(fromAppKit: display.appKitFrame, layout: layout)
    }

    /// The display (if any) whose Quartz-global frame contains `point`.
    public static func display(containing point: CGPoint, layout: DisplayLayout) -> DisplayDescriptor? {
        layout.displays.first { display in
            guard let frame = globalFrame(of: display, layout: layout) else { return false }
            return frame.contains(point)
        }
    }

    /// Every display whose Quartz-global frame intersects `rect`, in
    /// `layout.displays` order. Used for rects that span more than one
    /// display (plan §4.7).
    public static func displays(intersecting rect: GlobalRect, layout: DisplayLayout) -> [DisplayDescriptor] {
        layout.displays.filter { display in
            guard let frame = globalFrame(of: display, layout: layout) else { return false }
            return frame.intersects(rect)
        }
    }

    /// Converts a rect in Quartz global **points** into `display`'s own local
    /// **pixel** space (top-left origin at the display's top-left corner,
    /// scaled by its `backingScaleFactor`). Used to turn a capture selection
    /// into a per-display pixel rect when a selection spans several displays
    /// of different scales (plan §4.7). Returns `nil` if `layout` has no main
    /// display (needed to establish the shared Quartz-global origin).
    public static func pixelRect(of rect: GlobalRect, on display: DisplayDescriptor, layout: DisplayLayout) -> CGRect? {
        guard let displayFrame = globalFrame(of: display, layout: layout) else { return nil }
        let localPoints = CGRect(
            x: rect.origin.x - displayFrame.origin.x,
            y: rect.origin.y - displayFrame.origin.y,
            width: rect.width,
            height: rect.height
        )
        let scale = display.backingScaleFactor
        return localPoints.applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}
