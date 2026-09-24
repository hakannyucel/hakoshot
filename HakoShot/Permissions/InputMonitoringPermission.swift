import AppKit
import CoreGraphics
import Foundation
import IOKit.hidsystem
import os

/// Input Monitoring TCC helpers (plan §1.8): the listen-only keystroke event
/// tap (`KeystrokeTap`) needs it; nothing else in recording does (clicks use
/// `NSEvent` mouse monitors, which need no permission). Narrower than
/// Accessibility, which the app never asks for.
///
/// Reading `status` / `isGranted` never prompts. `request()` shows the
/// system prompt once (it adds HakoShot to the list); only UI code calls it
/// ("Show keystrokes" turned on, Settings). Recording code only preflights
/// and stays silently off (`KeystrokeTap.Status.permissionMissing`).
///
/// After granting, the tap often only works once the app is relaunched
/// (plan §1.8: the UI offers "Relaunch HakoShot").
///
/// Reset for testing: `tccutil reset ListenEvent com.hakanyucel.HakoShot`.
nonisolated enum InputMonitoringPermission {
    enum Status: String, Sendable, Equatable {
        case granted
        case denied
        /// Never asked (or the answer is not known).
        case notDetermined

        var isGranted: Bool { self == .granted }
    }

    /// System Settings anchor for Privacy & Security → Input Monitoring.
    static let paneAnchor = "Privacy_ListenEvent"

    static var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?\(paneAnchor)")
    }

    /// Tri-state status from IOKit (`IOHIDCheckAccess`), which tells "denied"
    /// from "never asked". Never prompts.
    static var status: Status {
        let access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        if access == kIOHIDAccessTypeGranted { return .granted }
        if access == kIOHIDAccessTypeDenied { return .denied }
        // IOKit can say "unknown" while CoreGraphics already knows.
        return CGPreflightListenEventAccess() ? .granted : .notDetermined
    }

    /// What the event tap checks before it starts. Never prompts.
    static var isGranted: Bool { CGPreflightListenEventAccess() }

    /// Prompts once (adds the app to the list); later calls return the
    /// stored decision without prompting. UI only, never during a recording.
    @discardableResult
    static func request() -> Bool {
        Log.permissions.notice("requesting Input Monitoring access")
        let granted = CGRequestListenEventAccess()
        Log.permissions.notice("Input Monitoring granted: \(granted)")
        return granted
    }

    /// Throws `RecordingError.permissionDenied(.inputMonitoring)` unless
    /// already granted. Never prompts.
    static func requireGranted() throws(RecordingError) {
        guard isGranted else { throw .permissionDenied(.inputMonitoring) }
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
