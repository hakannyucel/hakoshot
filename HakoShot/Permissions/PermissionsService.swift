import os
import AppKit
import ApplicationServices
import CoreGraphics
import Observation

/// Screen Recording and Accessibility permission checks (plan §2.1).
/// `refresh()` re-reads the TCC state; views observe the published flags.
@Observable
final class PermissionsService {
    private(set) var screenRecordingGranted: Bool
    private(set) var accessibilityGranted: Bool

    init() {
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        accessibilityGranted = AXIsProcessTrusted()
        Log.permissions.notice("launch state: screen recording \(self.screenRecordingGranted), accessibility \(self.accessibilityGranted)")
    }

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        let ax = AXIsProcessTrusted()
        if screen != screenRecordingGranted {
            screenRecordingGranted = screen
            Log.permissions.notice("screen recording granted: \(screen)")
        }
        if ax != accessibilityGranted {
            accessibilityGranted = ax
            Log.permissions.notice("accessibility granted: \(ax)")
        }
    }

    // MARK: Screen Recording

    /// Shows the system prompt (only the first time; afterwards macOS just
    /// returns the current state). Returns whether access is granted now.
    /// Granting usually takes effect only after relaunching the app.
    @discardableResult
    func requestScreenRecording() -> Bool {
        Log.permissions.notice("requesting screen recording access")
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted
    }

    // MARK: Accessibility (needed only for auto-scroll, requested lazily)

    /// Prompts for Accessibility if not trusted yet. Returns the current state.
    @discardableResult
    func requestAccessibility() -> Bool {
        Log.permissions.notice("requesting accessibility access")
        // Literal value of kAXTrustedCheckOptionPrompt; the global is not concurrency-safe in Swift 6.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        refresh()
        return trusted
    }

    /// Synthetic event posting (auto-scroll). Separate TCC bucket from AX on recent macOS.
    var postEventGranted: Bool { CGPreflightPostEventAccess() }

    @discardableResult
    func requestPostEvent() -> Bool {
        Log.permissions.notice("requesting post-event access")
        return CGRequestPostEventAccess()
    }

    // MARK: System Settings

    enum Pane: String {
        case screenRecording = "Privacy_ScreenCapture"
        case accessibility = "Privacy_Accessibility"
        case microphone = "Privacy_Microphone"
        case camera = "Privacy_Camera"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    func openSystemSettings(_ pane: Pane) {
        Self.openSystemSettings(pane)
    }

    /// Same as the instance method, for places without the service (HUD, Settings rows).
    static func openSystemSettings(_ pane: Pane) {
        let string = "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)"
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}
