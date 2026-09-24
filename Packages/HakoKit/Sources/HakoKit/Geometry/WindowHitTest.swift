import CoreGraphics
import Foundation

/// One on-screen window as `CGWindowListCopyWindowInfo` describes it, reduced
/// to what window capture needs (plan §4.4). `frame` is in **Quartz global**
/// points (`kCGWindowBounds` already uses that space).
public struct WindowDescriptor: Sendable, Equatable, Hashable, Identifiable {
    /// `kCGWindowNumber`; equal to ScreenCaptureKit's `SCWindow.windowID`.
    public var id: CGWindowID
    public var frame: CGRect
    /// `kCGWindowLayer` (0 = normal app windows, 24 = menu bar, 25 = status items…).
    public var layer: Int
    /// `kCGWindowAlpha`, 0…1.
    public var alpha: Double
    public var ownerPID: Int32
    public var ownerName: String
    /// `kCGWindowName`; only present when the app has Screen Recording access.
    public var title: String?

    public init(
        id: CGWindowID, frame: CGRect, layer: Int = 0, alpha: Double = 1,
        ownerPID: Int32, ownerName: String, title: String? = nil
    ) {
        self.id = id
        self.frame = frame
        self.layer = layer
        self.alpha = alpha
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.title = title
    }
}

/// Which windows count as capture targets (plan §4.4 filter).
public struct WindowEligibility: Sendable, Equatable {
    /// `kCGWindowLayer` range kept. Normal windows are 0, floating panels up
    /// to the menu bar level (24); status items (25+) and overlays are dropped.
    public var layers: ClosedRange<Int>
    /// Minimum width and height in points.
    public var minimumSize: CGSize
    /// Owners that never count (menu bar, Dock/desktop, system chrome).
    public var excludedOwnerNames: Set<String>
    /// Typically HakoShot's own PID, so the overlay never hit-tests itself.
    public var excludedPIDs: Set<Int32>

    public init(
        layers: ClosedRange<Int> = 0...24,
        minimumSize: CGSize = CGSize(width: 40, height: 40),
        excludedOwnerNames: Set<String> = WindowEligibility.systemOwnerNames,
        excludedPIDs: Set<Int32> = []
    ) {
        self.layers = layers
        self.minimumSize = minimumSize
        self.excludedOwnerNames = excludedOwnerNames
        self.excludedPIDs = excludedPIDs
    }

    /// Menu bar and wallpaper/Dock windows (plan §4.4), plus the system
    /// processes that draw full-screen chrome on normal-ish layers.
    public static let systemOwnerNames: Set<String> = [
        "Window Server", "Dock", "WindowManager", "Control Center", "SystemUIServer", "Notification Center",
    ]

    public static let `default` = WindowEligibility()

    public func accepts(_ window: WindowDescriptor) -> Bool {
        layers.contains(window.layer)
            && window.alpha > 0
            && window.frame.width >= minimumSize.width
            && window.frame.height >= minimumSize.height
            && !excludedOwnerNames.contains(window.ownerName)
            && !excludedPIDs.contains(window.ownerPID)
    }
}

/// Pure window selection logic: parsing `CGWindowListCopyWindowInfo`
/// dictionaries, filtering and point hit-testing. The app's `WindowLocator`
/// feeds it the live list; tests feed it fake lists.
public enum WindowHitTest {
    /// Parses one `CGWindowListCopyWindowInfo` entry. Returns `nil` when the
    /// id, bounds or owner PID is missing.
    public static func descriptor(from info: [String: Any]) -> WindowDescriptor? {
        guard let id = integer(info[kCGWindowNumber as String]),
              let pid = integer(info[kCGWindowOwnerPID as String]),
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let x = number(bounds["X"]), let y = number(bounds["Y"]),
              let width = number(bounds["Width"]), let height = number(bounds["Height"])
        else { return nil }
        let title = (info[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WindowDescriptor(
            id: CGWindowID(truncatingIfNeeded: id),
            frame: CGRect(x: x, y: y, width: width, height: height),
            layer: integer(info[kCGWindowLayer as String]) ?? 0,
            alpha: number(info[kCGWindowAlpha as String]).map(Double.init) ?? 1,
            ownerPID: Int32(truncatingIfNeeded: pid),
            ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
            title: title
        )
    }

    /// Parses and filters a front-to-back window list, keeping its order.
    public static func eligibleWindows(from infos: [[String: Any]], rules: WindowEligibility = .default) -> [WindowDescriptor] {
        eligibleWindows(infos.compactMap(descriptor(from:)), rules: rules)
    }

    public static func eligibleWindows(_ windows: [WindowDescriptor], rules: WindowEligibility = .default) -> [WindowDescriptor] {
        windows.filter(rules.accepts)
    }

    /// The front-most window of `windows` (front-to-back order) containing
    /// `point` (Quartz global). The list should already be filtered.
    public static func window(at point: CGPoint, in windows: [WindowDescriptor]) -> WindowDescriptor? {
        windows.first { $0.frame.contains(point) }
    }

    /// Whether a single window in front of `window` (earlier in the
    /// front-to-back list) completely contains it. Conservative: several
    /// windows jointly covering it are not detected.
    public static func isFullyCovered(_ window: WindowDescriptor, in windows: [WindowDescriptor]) -> Bool {
        guard let index = windows.firstIndex(where: { $0.id == window.id }) else { return false }
        return windows[..<index].contains { $0.frame.contains(window.frame) }
    }

    // MARK: Value coercion (CF numbers arrive as NSNumber; tests pass Swift values)

    private static func number(_ value: Any?) -> CGFloat? {
        switch value {
        case let v as CGFloat: v
        case let v as Double: CGFloat(v)
        case let v as Int: CGFloat(v)
        case let v as NSNumber: CGFloat(v.doubleValue)
        default: nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: v
        case let v as Int32: Int(v)
        case let v as UInt32: Int(v)
        case let v as NSNumber: v.intValue
        default: nil
        }
    }
}
