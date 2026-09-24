import AppKit
import CoreGraphics
import HakoKit
import os

/// Notch handling for fullscreen captures (plan §4.6): on a display with a
/// camera housing, the menu-bar strip beside the notch is cut from the top.
/// Area and window captures are never cropped. Math lives in
/// `HakoKit.NotchMath`; this type only reads `NSScreen`.
enum NotchCropper {
    /// Whether `displayID` has a notch.
    static func hasNotch(_ displayID: CGDirectDisplayID) -> Bool {
        guard let screen = DisplayLayoutProvider.screen(for: displayID) else { return false }
        return NotchMath.hasNotch(
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }

    /// Points to pass as `captureDisplay(_:showsCursor:mode:topInsetToCrop:)`;
    /// `0` when cropping is off or the display has no notch.
    static func topInsetToCrop(for displayID: CGDirectDisplayID, enabled: Bool) -> CGFloat {
        guard enabled, let screen = DisplayLayoutProvider.screen(for: displayID) else { return 0 }
        let auxiliaryHeight = [screen.auxiliaryTopLeftArea, screen.auxiliaryTopRightArea]
            .compactMap { $0?.height }
            .max()
        let inset = NotchMath.topCropInset(
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopHeight: auxiliaryHeight,
            displayHeight: screen.frame.height,
            scale: screen.backingScaleFactor
        )
        if inset > 0 {
            Log.capture.debug("notch crop \(inset) pt on \(screen.localizedName, privacy: .public)")
        }
        return inset
    }

    /// Convenience that reads `cropNotch` from settings.
    static func topInsetToCrop(for displayID: CGDirectDisplayID, settings: AppSettings = .shared) -> CGFloat {
        topInsetToCrop(for: displayID, enabled: settings.value(for: .cropNotch))
    }
}
