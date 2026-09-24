import AppKit
import HakoKit

/// One display as the overlay sees it: the `NSScreen`, its HakoKit descriptor
/// and its frame in Quartz global points.
struct OverlayDisplay {
    let screen: NSScreen
    let descriptor: DisplayDescriptor
    /// The display's frame in Quartz global points (top-left origin).
    let globalFrame: GlobalRect

    var id: CGDirectDisplayID { descriptor.id }
    var scale: CGFloat { descriptor.backingScaleFactor }
}

/// Snapshot of the display arrangement for one overlay session, plus the only
/// AppKit ↔ Quartz conversions the overlay uses (all via `ScreenGeometry`).
struct OverlayScreens {
    let layout: DisplayLayout
    let displays: [OverlayDisplay]

    /// Current `NSScreen.screens`; `nil` if there is no screen (headless).
    static func current() -> OverlayScreens? {
        let screens = NSScreen.screens
        guard let main = screens.first, let mainID = displayID(of: main) else { return nil }
        let descriptors: [(NSScreen, DisplayDescriptor)] = screens.compactMap { screen in
            guard let id = displayID(of: screen) else { return nil }
            return (screen, DisplayDescriptor(id: id, appKitFrame: screen.frame, backingScaleFactor: screen.backingScaleFactor))
        }
        let layout = DisplayLayout(displays: descriptors.map(\.1), mainDisplayID: mainID)
        let displays: [OverlayDisplay] = descriptors.compactMap { screen, descriptor in
            guard let frame = ScreenGeometry.globalFrame(of: descriptor, layout: layout) else { return nil }
            return OverlayDisplay(screen: screen, descriptor: descriptor, globalFrame: frame)
        }
        guard !displays.isEmpty else { return nil }
        return OverlayScreens(layout: layout, displays: displays)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value
    }

    // MARK: Lookup

    func display(withID id: CGDirectDisplayID) -> OverlayDisplay? {
        displays.first { $0.id == id }
    }

    func display(containing point: CGPoint) -> OverlayDisplay? {
        displays.first { $0.globalFrame.contains(point) }
    }

    /// The display containing `point`, or else the closest one. Points on a
    /// display's right/bottom edge (outside `contains`) still resolve.
    func display(nearest point: CGPoint) -> OverlayDisplay? {
        if let hit = display(containing: point) { return hit }
        return displays.min { distance(from: point, to: $0.globalFrame) < distance(from: point, to: $1.globalFrame) }
    }

    private func distance(from point: CGPoint, to rect: GlobalRect) -> CGFloat {
        let clamped = SelectionMath.clamp(point, to: rect)
        return hypot(point.x - clamped.x, point.y - clamped.y)
    }

    // MARK: Conversion (ScreenGeometry only)

    /// AppKit global point (e.g. `NSEvent.mouseLocation`) → Quartz global point.
    func globalPoint(fromAppKit point: CGPoint) -> CGPoint {
        let rect = CGRect(origin: point, size: .zero)
        // `layout` always has a main display (checked in `current()`).
        return ScreenGeometry.globalRect(fromAppKit: rect, layout: layout)?.origin ?? point
    }

    /// Quartz global rect → rect in `display`'s view coordinates (AppKit,
    /// bottom-left origin at the display's bottom-left corner).
    func localRect(_ rect: GlobalRect, in display: OverlayDisplay) -> CGRect {
        let appKit = ScreenGeometry.appKitRect(fromGlobal: rect, layout: layout) ?? rect.cgRect
        return appKit.offsetBy(dx: -display.screen.frame.minX, dy: -display.screen.frame.minY)
    }

    /// Quartz global point → point in `display`'s view coordinates.
    func localPoint(_ point: CGPoint, in display: OverlayDisplay) -> CGPoint {
        localRect(GlobalRect(origin: point, size: .zero), in: display).origin
    }
}
