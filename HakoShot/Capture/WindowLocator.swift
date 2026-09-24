import AppKit
import CoreGraphics
import Foundation
import HakoKit
import os

/// A capturable window under the cursor (plan §4.4).
nonisolated struct LocatedWindow: Sendable, Equatable, Hashable, Identifiable {
    /// `kCGWindowNumber` == `SCWindow.windowID`; pass to
    /// `ScreenCaptureService.captureWindow(_:options:)`.
    let id: CGWindowID
    /// Quartz global points (window frame without shadow).
    let frame: GlobalRect
    let ownerName: String
    /// Window title; `nil` if the window has none.
    let title: String?
    let ownerPID: pid_t

    init(_ descriptor: WindowDescriptor) {
        id = descriptor.id
        frame = GlobalRect(origin: descriptor.frame.origin, size: descriptor.frame.size)
        ownerName = descriptor.ownerName
        title = descriptor.title
        ownerPID = descriptor.ownerPID
    }

    /// Label for the highlight: "Owner — Title", or just the owner.
    var displayName: String {
        guard let title, !title.isEmpty, title != ownerName else { return ownerName }
        return "\(ownerName) — \(title)"
    }
}

/// Snapshot of on-screen windows, front to back, for window-mode hit testing.
///
/// Take one snapshot when the overlay opens (`WindowLocator.snapshot()`), then
/// call `window(at:)` on every mouse move — the plan's "list once, hit-test on
/// move" (§4.4). HakoShot's own windows (overlay panels etc.), the menu bar,
/// Dock/wallpaper, status items and tiny/transparent windows are filtered out
/// by HakoKit's `WindowHitTest`.
nonisolated struct WindowLocator: Sendable {
    /// Eligible windows, front-most first.
    let windows: [LocatedWindow]

    init(windows: [LocatedWindow]) {
        self.windows = windows
    }

    /// System agents whose windows are chrome, not capture targets. Matched
    /// by bundle ID because `kCGWindowOwnerName` is localized (e.g. Notification
    /// Center is "Bildirim Merkezi" in Turkish and covers the whole screen).
    static let systemBundleIDs: Set<String> = [
        "com.apple.dock", "com.apple.notificationcenterui", "com.apple.controlcenter",
        "com.apple.WindowManager", "com.apple.systemuiserver", "com.apple.wallpaper.agent",
        "com.apple.Spotlight", "com.apple.TextInputMenuAgent",
    ]

    /// Default rules: our own process and `systemBundleIDs` excluded.
    static func defaultRules() -> WindowEligibility {
        var pids: Set<pid_t> = [ProcessInfo.processInfo.processIdentifier]
        for app in NSWorkspace.shared.runningApplications {
            if let bundleID = app.bundleIdentifier, systemBundleIDs.contains(bundleID) {
                pids.insert(app.processIdentifier)
            }
        }
        return WindowEligibility(excludedPIDs: pids)
    }

    /// Reads the live window list (`CGWindowListCopyWindowInfo`, thread-safe,
    /// a few ms). Our own process and system chrome are always excluded.
    static func snapshot(rules: WindowEligibility = WindowLocator.defaultRules()) -> WindowLocator {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let infos = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let eligible = WindowHitTest.eligibleWindows(from: infos, rules: rules)
        Log.capture.debug("window snapshot: \(eligible.count) of \(infos.count) windows eligible")
        return WindowLocator(windows: eligible.map(LocatedWindow.init))
    }

    /// Front-most eligible window containing `point` (Quartz global points).
    func window(at point: CGPoint) -> LocatedWindow? {
        windows.first { $0.frame.contains(point) }
    }

    func window(withID id: CGWindowID) -> LocatedWindow? {
        windows.first { $0.id == id }
    }

    /// One-shot convenience: fresh snapshot + hit test.
    static func window(at point: CGPoint) -> LocatedWindow? {
        snapshot().window(at: point)
    }

    /// Front-most eligible window of `pid` (e.g. the frontmost app), else
    /// the front-most eligible window of any app.
    func frontmostWindow(preferringPID pid: pid_t?) -> LocatedWindow? {
        if let pid, let match = windows.first(where: { $0.ownerPID == pid }) { return match }
        return windows.first
    }
}

extension WindowLocator {
    /// Quartz global position of the mouse cursor.
    static var mouseLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
