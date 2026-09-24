import AppKit
import CoreGraphics
import HakoKit

/// Builds HakoKit's `DisplayLayout` from `NSScreen.screens` and maps between
/// `NSScreen`, `CGDirectDisplayID` and ScreenCaptureKit's `SCDisplay`
/// (which carries the same `displayID`). AppKit is main-actor only, so this is
/// the one place that reads screen geometry; everything else works on the
/// `Sendable` `DisplayLayout` value.
enum DisplayLayoutProvider {
    private static let screenNumberKey = NSDeviceDescriptionKey("NSScreenNumber")

    /// The current display arrangement. `NSScreen.screens[0]` is the main
    /// (menu bar) display and defines Quartz global space's origin.
    static func currentLayout() -> DisplayLayout {
        let screens = NSScreen.screens
        let displays = screens.compactMap(descriptor(for:))
        let mainID = screens.first.flatMap(displayID(of:)) ?? CGMainDisplayID()
        return DisplayLayout(displays: displays, mainDisplayID: mainID)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[screenNumberKey] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    static func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { self.displayID(of: $0) == displayID }
    }

    static func descriptor(for screen: NSScreen) -> DisplayDescriptor? {
        guard let id = displayID(of: screen) else { return nil }
        return DisplayDescriptor(id: id, appKitFrame: screen.frame, backingScaleFactor: screen.backingScaleFactor)
    }

    /// The display under the mouse cursor (fullscreen default, plan §4.7).
    static func displayUnderMouse() -> CGDirectDisplayID? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) }.flatMap(displayID(of:))
    }
}
