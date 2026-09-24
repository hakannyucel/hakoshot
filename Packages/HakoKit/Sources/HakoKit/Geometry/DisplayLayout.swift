import CoreGraphics

/// A rect in **Quartz global space**: top-left origin, positioned at the main
/// display's top-left corner, y increasing downward. This is the coordinate
/// space every other part of HakoShot (capture, overlay, annotation frames)
/// agrees to use internally (plan §3.2). AppKit's `NSScreen.frame` values
/// (bottom-left origin) are converted to/from this space only through
/// `ScreenGeometry` — nowhere else is `y` flipped by hand.
public struct GlobalRect: Sendable, Equatable, Hashable {
    public var origin: CGPoint
    public var size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }

    /// The underlying `CGRect`, still in Quartz global space.
    public var cgRect: CGRect {
        CGRect(origin: origin, size: size)
    }

    public var minX: CGFloat { cgRect.minX }
    public var minY: CGFloat { cgRect.minY }
    public var maxX: CGFloat { cgRect.maxX }
    public var maxY: CGFloat { cgRect.maxY }
    public var midX: CGFloat { cgRect.midX }
    public var midY: CGFloat { cgRect.midY }
    public var width: CGFloat { size.width }
    public var height: CGFloat { size.height }

    public func contains(_ point: CGPoint) -> Bool {
        cgRect.contains(point)
    }

    public func intersects(_ other: GlobalRect) -> Bool {
        cgRect.intersects(other.cgRect)
    }

    public func intersection(_ other: GlobalRect) -> GlobalRect {
        GlobalRect(origin: cgRect.intersection(other.cgRect).origin, size: cgRect.intersection(other.cgRect).size)
    }
}

/// One display, described in **AppKit's** coordinate space (bottom-left
/// origin, positioned relative to the union of all `NSScreen.screens`).
/// HakoKit never imports AppKit, so the app target builds these from
/// `NSScreen` (`frame`, `backingScaleFactor`) and `CGDirectDisplayID`
/// (`NSScreen.deviceDescription[.init("NSScreenNumber")]`).
public struct DisplayDescriptor: Sendable, Equatable, Hashable, Identifiable {
    public var id: CGDirectDisplayID
    /// `NSScreen.frame`, bottom-left origin, points.
    public var appKitFrame: CGRect
    /// `NSScreen.backingScaleFactor` (1.0 non-Retina, 2.0 Retina, …).
    public var backingScaleFactor: CGFloat

    public init(id: CGDirectDisplayID, appKitFrame: CGRect, backingScaleFactor: CGFloat) {
        self.id = id
        self.appKitFrame = appKitFrame
        self.backingScaleFactor = backingScaleFactor
    }
}

/// The full set of displays as AppKit reports them, plus which one is "main".
///
/// The main display is `NSScreen.screens[0]` — the one carrying the menu bar.
/// Its AppKit frame's top-left corner defines the origin of Quartz global
/// space (see `GlobalRect`).
public struct DisplayLayout: Sendable, Equatable {
    public var displays: [DisplayDescriptor]
    public var mainDisplayID: CGDirectDisplayID

    public init(displays: [DisplayDescriptor], mainDisplayID: CGDirectDisplayID) {
        self.displays = displays
        self.mainDisplayID = mainDisplayID
    }

    public var mainDisplay: DisplayDescriptor? {
        display(withID: mainDisplayID)
    }

    public func display(withID id: CGDirectDisplayID) -> DisplayDescriptor? {
        displays.first { $0.id == id }
    }
}
