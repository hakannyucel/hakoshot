@preconcurrency import AVFoundation
import AppKit
import Foundation
import os

/// Camera / microphone authorization state (plan §1.8).
nonisolated enum MediaAuthorization: String, Sendable, Equatable {
    case notDetermined
    case denied
    case restricted
    case authorized

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .denied
        }
    }

    var isGranted: Bool { self == .authorized }
    /// The user has to go to System Settings (a request won't prompt again).
    var needsSystemSettings: Bool { self == .denied || self == .restricted }
}

/// Microphone TCC helpers (AVCaptureDevice `.audio`). Plan §1.8: requested
/// when the mic is first turned on in the HUD. Needs
/// `NSMicrophoneUsageDescription` in Info.plist and the
/// `com.apple.security.device.audio-input` entitlement under the hardened
/// runtime (R2.I); without them the request crashes / is refused.
nonisolated enum MediaPermissions {
    static var microphone: MediaAuthorization {
        MediaAuthorization(AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Shows the system prompt when undetermined; otherwise returns the
    /// current state without prompting. Returns whether access is granted.
    static func requestMicrophone() async -> Bool {
        switch microphone {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            Log.permissions.notice("requesting microphone access")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            Log.permissions.notice("microphone granted: \(granted)")
            return granted
        }
    }
}

extension PermissionsService {
    /// Current microphone authorization (read live; not observed — call
    /// again after `requestMicrophone()` or when the app becomes active).
    var microphoneAuthorization: MediaAuthorization { MediaPermissions.microphone }

    var microphoneGranted: Bool { microphoneAuthorization.isGranted }

    /// Prompts once; afterwards returns the stored decision.
    @discardableResult
    func requestMicrophone() async -> Bool {
        await MediaPermissions.requestMicrophone()
    }

    /// Opens System Settings › Privacy & Security › Microphone.
    func openMicrophoneSettings() {
        openSystemSettings(.microphone)
    }
}
