import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Builds the `SCContentFilter` of a recording stream (plan §4.1, §4.5).
///
/// Rules:
/// - HakoShot's own windows are left out by excluding **our application**
///   (`excludingApplications:`), which also covers windows created after the
///   content was fetched (control bar, Quick Access, HUD).
/// - `exceptedWindowIDs` are our windows that must still be recorded
///   (`exceptingWindows:`): classic overlays (clicks, keystrokes), the webcam
///   bubble. The content must be fetched **after** they are on screen,
///   otherwise SCK doesn't list them (`fetchContent()` always fetches fresh,
///   never from `ShareableContentCache`).
/// - `hidesDesktopIcons`: Finder icon / widget windows are dropped the same
///   way `DesktopIconFilter` does for screenshots (owner apps excluded, their
///   normal windows kept as exceptions).
/// - `excludesNotifications` (DND layer 1, plan §4.11): Notification Center
///   banners (non-desktop-layer windows of `com.apple.notificationcenterui`)
///   are dropped; desktop widgets stay unless icons are hidden too.
///
/// Window mode (plan §4.1, R1.4): a **display filter that includes only the
/// target window** (`SCContentFilter(display:including:)`) plus the excepted
/// overlay windows, with `sourceRect` = the window frame. A display filter
/// (not `desktopIndependentWindow:`) is what lets `WindowFollower` move the
/// `sourceRect` while the window moves, and keeps overlays (clicks,
/// keystrokes, webcam) in the video. Child windows (sheets) come along
/// because `SCStreamConfiguration.includeChildWindows` defaults to `true`;
/// the desktop, Dock, menu bar, notifications and every other window are
/// out by construction. `.application` includes the target's whole app
/// instead (menus and windows opened later are recorded too; anything of
/// that app overlapping the rect shows).
///
/// The decision is a pure function over a small snapshot of the shareable
/// content (`plan(_:snapshot:)`, unit tested); `makeFilter` only maps it
/// onto SCK objects.
///
/// All macOS-version-dependent assumptions about which process owns what live
/// here and in `DesktopIconFilter` (plan §9.1 K4).
nonisolated enum ContentFilterBuilder {
    static let notificationCenterBundleID = "com.apple.notificationcenterui"

    /// How a window-mode recording filters (plan §5.2 default: window + child windows).
    enum WindowFilterStrategy: String, Sendable, Equatable, CaseIterable {
        /// Only the target window (and its child windows) + excepted overlays.
        case window
        /// Every window of the target's application + excepted overlays.
        case application
    }

    /// The window being recorded in window mode.
    struct WindowTarget: Sendable, Equatable {
        var windowID: CGWindowID
        var strategy: WindowFilterStrategy = .window
    }

    struct Options: Sendable, Equatable {
        var displayID: CGDirectDisplayID
        var exceptedWindowIDs: [CGWindowID] = []
        var hidesDesktopIcons = false
        var excludesNotifications = false
        /// `nil` = area / fullscreen (display filter, `sourceRect` decides the area).
        var window: WindowTarget?
        var ownPID: pid_t = ProcessInfo.processInfo.processIdentifier
    }

    /// Options for a source configuration: window targets get a window
    /// filter, everything else a display filter. DND layer 1 comes from
    /// `configuration.excludesNotifications` (the engine sets it from
    /// `RecordingOptions.doNotDisturb`).
    static func options(
        for configuration: RecordingSourceConfiguration,
        hidesDesktopIcons: Bool,
        windowStrategy: WindowFilterStrategy = .window
    ) -> Options {
        var options = Options(
            displayID: configuration.displayID,
            exceptedWindowIDs: configuration.exceptedWindowIDs,
            hidesDesktopIcons: hidesDesktopIcons,
            excludesNotifications: configuration.excludesNotifications
        )
        if case let .window(windowID) = configuration.target {
            options.window = WindowTarget(windowID: windowID, strategy: windowStrategy)
        }
        return options
    }

    /// Fresh shareable content (on-screen windows only).
    nonisolated(nonsending) static func fetchContent() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    // MARK: Pure plan

    /// The parts of `SCShareableContent` the decision needs.
    struct ContentSnapshot: Sendable, Equatable {
        struct Window: Sendable, Equatable {
            var id: CGWindowID
            var pid: pid_t?
            var bundleID: String?
            var layer: Int
        }

        struct Application: Sendable, Equatable {
            var pid: pid_t
            var bundleID: String
        }

        var windows: [Window]
        var applications: [Application]
    }

    /// Which `SCContentFilter` initializer to use and with what. IDs keep the
    /// snapshot's order (window lists: target first).
    enum FilterPlan: Sendable, Equatable {
        /// `init(display:excludingApplications:exceptingWindows:)` — area / fullscreen.
        case excludingApplications(pids: [pid_t], exceptingWindows: [CGWindowID])
        /// `init(display:excludingWindows:)` — our app isn't listed yet.
        case excludingWindows([CGWindowID])
        /// `init(display:including:)` — window mode.
        case includingWindows([CGWindowID])
        /// `init(display:including:exceptingWindows:)` — window mode, whole app.
        /// Excepted windows of *other* apps (our overlays) are shown.
        case includingApplications(pids: [pid_t], exceptingWindows: [CGWindowID])

        var isWindowMode: Bool {
            switch self {
            case .includingWindows, .includingApplications: true
            case .excludingApplications, .excludingWindows: false
            }
        }
    }

    /// Decides the filter. Throws `RecordingError.windowNotFound` when the
    /// window target isn't in the snapshot (closed or off screen).
    static func plan(_ options: Options, snapshot: ContentSnapshot) throws -> FilterPlan {
        if let window = options.window {
            return try windowPlan(window, options: options, snapshot: snapshot)
        }
        return displayPlan(options, snapshot: snapshot)
    }

    private static func displayPlan(_ options: Options, snapshot: ContentSnapshot) -> FilterPlan {
        let excepted = Set(options.exceptedWindowIDs)
        let decorationOwners = decorationOwnerBundleIDs(options)
        let ownApps = snapshot.applications.filter { $0.pid == options.ownPID }

        if !ownApps.isEmpty {
            let otherApps = snapshot.applications.filter { decorationOwners.contains($0.bundleID) }
            var kept = snapshot.windows.filter { $0.pid == options.ownPID && excepted.contains($0.id) }
            kept += snapshot.windows.filter { window in
                guard let bundleID = window.bundleID, decorationOwners.contains(bundleID) else { return false }
                return !isDropped(bundleID: bundleID, layer: window.layer, options: options)
            }
            return .excludingApplications(pids: (ownApps + otherApps).map(\.pid), exceptingWindows: kept.map(\.id))
        }

        // Our app isn't listed (no on-screen window yet): exclude our listed
        // windows one by one. Windows created later would be recorded, so
        // callers show their UI before starting.
        let dropped = snapshot.windows.filter { window in
            if window.pid == options.ownPID { return !excepted.contains(window.id) }
            guard let bundleID = window.bundleID, decorationOwners.contains(bundleID) else { return false }
            return isDropped(bundleID: bundleID, layer: window.layer, options: options)
        }
        return .excludingWindows(dropped.map(\.id))
    }

    private static func windowPlan(_ target: WindowTarget, options: Options, snapshot: ContentSnapshot) throws -> FilterPlan {
        guard let targetWindow = snapshot.windows.first(where: { $0.id == target.windowID }) else {
            throw RecordingError.windowNotFound(target.windowID)
        }
        let excepted = Set(options.exceptedWindowIDs).subtracting([target.windowID])
        let overlays = snapshot.windows.filter { excepted.contains($0.id) }.map(\.id)

        // Our own window as target (DEBUG test window): including our app
        // would record the control bar and HUD, so stay window-only.
        if target.strategy == .application, let pid = targetWindow.pid, pid != options.ownPID,
           snapshot.applications.contains(where: { $0.pid == pid }) {
            let foreignOverlays = snapshot.windows.filter { excepted.contains($0.id) && $0.pid != pid }.map(\.id)
            return .includingApplications(pids: [pid], exceptingWindows: foreignOverlays)
        }
        return .includingWindows([target.windowID] + overlays)
    }

    /// Owner apps whose windows are filtered individually.
    static func decorationOwnerBundleIDs(_ options: Options) -> Set<String> {
        var owners = Set<String>()
        if options.hidesDesktopIcons { owners.formUnion(DesktopIconFilter.ownerBundleIDs) }
        if options.excludesNotifications { owners.insert(notificationCenterBundleID) }
        return owners
    }

    /// Whether a window of a decoration owner app is left out of the video.
    static func isDropped(bundleID: String, layer: Int, options: Options) -> Bool {
        if DesktopIconFilter.isDesktopDecoration(bundleID: bundleID, layer: layer) {
            return options.hidesDesktopIcons
        }
        return options.excludesNotifications && bundleID == notificationCenterBundleID
    }

    /// Notification banner windows a plan leaves out (for the log).
    static func droppedNotificationWindowCount(_ options: Options, snapshot: ContentSnapshot) -> Int {
        snapshot.windows.filter { window in
            window.bundleID == notificationCenterBundleID
                && !DesktopIconFilter.isDesktopDecoration(bundleID: notificationCenterBundleID, layer: window.layer)
        }.count
    }

    // MARK: SCK mapping

    static func snapshot(of content: SCShareableContent) -> ContentSnapshot {
        ContentSnapshot(
            windows: content.windows.map {
                .init(
                    id: $0.windowID,
                    pid: $0.owningApplication?.processID,
                    bundleID: $0.owningApplication?.bundleIdentifier,
                    layer: $0.windowLayer
                )
            },
            applications: content.applications.map { .init(pid: $0.processID, bundleID: $0.bundleIdentifier) }
        )
    }

    /// The filter for `options`. Throws `RecordingError.displayNotFound` /
    /// `.windowNotFound`.
    static func makeFilter(_ options: Options, content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) else {
            throw RecordingError.displayNotFound(options.displayID)
        }
        let snapshot = snapshot(of: content)
        let plan = try plan(options, snapshot: snapshot)
        log(plan, options: options, snapshot: snapshot)

        func windows(_ ids: [CGWindowID]) -> [SCWindow] {
            let byID = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
            return ids.compactMap { byID[$0] }
        }
        func applications(_ pids: [pid_t]) -> [SCRunningApplication] {
            let wanted = Set(pids)
            return content.applications.filter { wanted.contains($0.processID) }
        }

        switch plan {
        case let .excludingApplications(pids, exceptingWindows):
            return SCContentFilter(display: display, excludingApplications: applications(pids), exceptingWindows: windows(exceptingWindows))
        case let .excludingWindows(ids):
            return SCContentFilter(display: display, excludingWindows: windows(ids))
        case let .includingWindows(ids):
            return SCContentFilter(display: display, including: windows(ids))
        case let .includingApplications(pids, exceptingWindows):
            return SCContentFilter(display: display, including: applications(pids), exceptingWindows: windows(exceptingWindows))
        }
    }

    private static func log(_ plan: FilterPlan, options: Options, snapshot: ContentSnapshot) {
        let kind: String = switch plan {
        case .excludingApplications: "display excluding apps"
        case .excludingWindows: "display excluding windows"
        case .includingWindows: "window only"
        case .includingApplications: "window's application"
        }
        // DND layer 1 (plan §4.11): make the exclusion visible in the log.
        let notifications: String
        if plan.isWindowMode {
            notifications = "notifications not included (window filter)"
        } else if options.excludesNotifications {
            notifications = "notifications excluded (\(droppedNotificationWindowCount(options, snapshot: snapshot)) banner windows now)"
        } else {
            notifications = "notifications recorded"
        }
        Log.recording.notice("filter: \(kind, privacy: .public), display \(options.displayID), window \(options.window.map { String($0.windowID) } ?? "-", privacy: .public), excepted \(options.exceptedWindowIDs.count), icons hidden \(options.hidesDesktopIcons), \(notifications, privacy: .public)")
    }
}
