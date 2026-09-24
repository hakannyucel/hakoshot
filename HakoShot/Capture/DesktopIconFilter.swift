import CoreGraphics
import Foundation
import os
@preconcurrency import ScreenCaptureKit

/// Identifies the windows that draw desktop icons and desktop widgets so a
/// capture can leave them out (plan §4.5 option A, risk R2/R4). There is no
/// public API for this; every assumption about window ownership lives here.
///
/// Spike, macOS 27 (build 27.0, 2026-09), two displays — SCShareableContent
/// (`excludingDesktopWindows: false, onScreenWindowsOnly: true`) and
/// `CGWindowListCopyWindowInfo` agree:
///
/// | Owner (bundle id)              | Layer                          | Title        | Frame           | What |
/// |--------------------------------|--------------------------------|--------------|-----------------|------|
/// | `com.apple.finder`             | −2147483603 (`desktopIconWindow`) | ""        | == display, one per display | **desktop icons** |
/// | `com.apple.notificationcenterui` (localized name, e.g. "Bildirim Merkezi") | −2147483601 (icon + 2) | widget name | 180×180 etc. | **desktop widgets**, one window each |
/// | Window Server (no app)         | −2147483602 (icon + 1)         | `underbelly` | top 94/122 pt of display | menu-bar backdrop; keep |
/// | `com.apple.WindowManager`      | −2147483624 (desktop − 1)      | `Wallpaper`  | == display      | wallpaper; keep |
/// | Window Server                  | −2147483626                    | `Display N Backstop` | == display | keep |
/// | `com.apple.loginwindow`        | −2147483625                    | nil          | 0×0             | keep |
///
/// Finder's ordinary windows are layer 0; Finder also keeps off-screen layer-0
/// helper windows. So the rule is: owner is Finder or a widget host **and** the
/// window sits below the normal window level. Owner *names* are localized, so
/// matching is by bundle id only.
nonisolated enum DesktopIconFilter {
    /// Apps whose below-normal-level windows are desktop icons.
    static let iconOwnerBundleIDs: Set<String> = ["com.apple.finder"]
    /// Apps whose below-normal-level windows are desktop widgets. `chronod`
    /// hosts widget extensions; listed defensively in case a later macOS moves
    /// the desktop widget windows there.
    static let widgetOwnerBundleIDs: Set<String> = ["com.apple.notificationcenterui", "com.apple.chronod"]

    static var ownerBundleIDs: Set<String> { iconOwnerBundleIDs.union(widgetOwnerBundleIDs) }

    /// `kCGNormalWindowLevel` (0): icons and widgets are always below it.
    static let normalLevel = Int(CGWindowLevelForKey(.normalWindow))
    /// `kCGDesktopWindowLevel`: the wallpaper band; icons are above it.
    static let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))

    /// Whether `window` draws desktop icons or widgets.
    static func isDesktopDecoration(bundleID: String?, layer: Int) -> Bool {
        guard let bundleID, ownerBundleIDs.contains(bundleID) else { return false }
        return layer > desktopLevel && layer < normalLevel
    }

    /// The icon and widget windows in `content`, for
    /// `SCContentFilter(display:excludingWindows:)`.
    static func excludedWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter {
            isDesktopDecoration(bundleID: $0.owningApplication?.bundleIdentifier, layer: $0.windowLayer)
        }
    }

    /// The apps that own icon/widget windows. Used with
    /// `SCContentFilter(display:excludingApplications:exceptingWindows:)`
    /// together with `keptWindows(from:)`: excluding whole apps keeps the
    /// "exclude our own app" rule (which also covers windows created after the
    /// content was fetched) while still dropping icons and widgets.
    static func ownerApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        content.applications.filter { ownerBundleIDs.contains($0.bundleIdentifier) }
    }

    /// The windows of `ownerApplications(in:)` that must stay visible: open
    /// Finder windows, Notification Center banners, and so on.
    static func keptWindows(from content: SCShareableContent) -> [SCWindow] {
        content.windows.filter { window in
            guard let bundleID = window.owningApplication?.bundleIdentifier,
                  ownerBundleIDs.contains(bundleID)
            else { return false }
            return !isDesktopDecoration(bundleID: bundleID, layer: window.windowLayer)
        }
    }

    // MARK: Wallpaper (for the Hide Desktop Icons cover)

    static let wallpaperOwnerBundleID = "com.apple.WindowManager"

    /// The on-screen wallpaper window covering `displayFrame` (SCK points,
    /// same space as `SCDisplay.frame`), if the system draws one.
    static func wallpaperWindow(in content: SCShareableContent, displayFrame: CGRect) -> SCWindow? {
        content.windows.first { window in
            window.owningApplication?.bundleIdentifier == wallpaperOwnerBundleID
                && window.windowLayer < desktopLevel + 2 && window.windowLayer > desktopLevel - 4
                && window.frame.equalTo(displayFrame)
        }
    }

    // MARK: Spike

    /// Logs every below-normal-level window (and every window of the owners
    /// above) so a macOS update that changes the layout shows up in Console.
    static func logDesktopWindows(in content: SCShareableContent) {
        for window in content.windows where window.windowLayer < normalLevel
            || ownerBundleIDs.contains(window.owningApplication?.bundleIdentifier ?? "") {
            let bundleID = window.owningApplication?.bundleIdentifier ?? "-"
            let excluded = isDesktopDecoration(bundleID: window.owningApplication?.bundleIdentifier, layer: window.windowLayer)
            Log.capture.debug(
                "desktop window \(window.windowID) owner=\(bundleID, privacy: .public) layer=\(window.windowLayer) title=\(window.title ?? "nil", privacy: .public) frame=\(String(describing: window.frame), privacy: .public) onScreen=\(window.isOnScreen) excluded=\(excluded)"
            )
        }
    }
}
