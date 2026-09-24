@preconcurrency import AVFoundation
import AppKit
import Foundation
import os

/// Camera TCC helpers (AVCaptureDevice `.video`, plan §1.8): requested when
/// the camera is first turned on in the HUD. Needs `NSCameraUsageDescription`
/// in Info.plist and `ENABLE_RESOURCE_ACCESS_CAMERA = YES` (the
/// `com.apple.security.device.camera` entitlement) under the hardened
/// runtime (R4.I); without the usage string `requestAccess` crashes.
///
/// Separate from `MediaPermissions` (R2.1 owns that file); reuses its
/// `MediaAuthorization`.
nonisolated enum CameraPermission {
    /// System Settings anchor for the Camera privacy pane.
    static let paneAnchor = "Privacy_Camera"

    /// Current state; reading it never prompts.
    static var status: MediaAuthorization {
        MediaAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
    }

    static var isGranted: Bool { status.isGranted }

    /// `NSCameraUsageDescription` is in Info.plist.
    static var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") != nil
    }

    /// Shows the system prompt when undetermined; otherwise returns the
    /// stored decision without prompting.
    static func request() async -> Bool {
        switch status {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            // Without the usage string the request crashes (until R4.I adds it).
            guard hasUsageDescription else {
                Log.permissions.error("NSCameraUsageDescription missing; not requesting camera access")
                return false
            }
            Log.permissions.notice("requesting camera access")
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            Log.permissions.notice("camera granted: \(granted)")
            return granted
        }
    }

    /// Throws `RecordingError.permissionDenied(.camera)` unless already
    /// authorized. Never prompts (capture code calls this; the UI requests).
    static func requireAuthorized() throws(RecordingError) {
        guard isGranted else { throw .permissionDenied(.camera) }
    }

    @MainActor
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(paneAnchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
