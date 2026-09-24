@preconcurrency import AVFoundation
import Foundation
import Observation
import os

extension Log {
    nonisolated static let camera = Logger(subsystem: subsystem, category: "camera")
}

/// One video input device (plan §1.5).
nonisolated struct CameraDevice: Sendable, Equatable, Hashable, Identifiable, Codable {
    enum Kind: String, Sendable, Codable {
        case builtIn
        case continuity
        case external
    }

    /// `AVCaptureDevice.uniqueID` (`CameraOptions.deviceID`,
    /// `SettingsKey.recordingCameraDeviceID`).
    var id: String
    var name: String
    var kind: Kind
}

/// A snapshot of the video devices and the system's preferred camera.
nonisolated struct CameraDeviceList: Sendable, Equatable, Codable {
    var devices: [CameraDevice]
    /// `AVCaptureDevice.systemPreferredCamera` (falls back to
    /// `default(for: .video)`).
    var defaultDeviceID: String?

    static let empty = CameraDeviceList(devices: [], defaultDeviceID: nil)

    var isEmpty: Bool { devices.isEmpty }

    var defaultDevice: CameraDevice? {
        defaultDeviceID.flatMap { id in devices.first { $0.id == id } } ?? devices.first
    }

    /// The device a setting records from: the chosen one if it is still
    /// connected, otherwise the default (a disconnected camera falls back
    /// instead of failing the recording). `nil` / "" = default.
    func resolve(_ deviceID: String?) -> CameraDevice? {
        if let deviceID, !deviceID.isEmpty, let device = devices.first(where: { $0.id == deviceID }) {
            return device
        }
        return defaultDevice
    }

    /// Discovery device types: built-in, Continuity Camera (iPhone) and
    /// external (USB / virtual). Continuity cameras only report
    /// `.continuityCamera` with `NSCameraUseContinuityCameraDeviceType` in
    /// Info.plist (R4.I); otherwise they appear as external.
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .continuityCamera, .external]

    /// Reads the connected cameras. Listing never prompts for TCC.
    static func current() -> CameraDeviceList {
        let session = AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified)
        let devices = session.devices.map { device in
            CameraDevice(id: device.uniqueID, name: device.localizedName, kind: kind(of: device))
        }
        let preferred = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
        return CameraDeviceList(devices: devices, defaultDeviceID: preferred?.uniqueID)
    }

    static func kind(of device: AVCaptureDevice) -> CameraDevice.Kind {
        switch device.deviceType {
        case .builtInWideAngleCamera: .builtIn
        case .continuityCamera: .continuity
        default: .external
        }
    }

    /// The `AVCaptureDevice` for a setting (`nil` / "" = default), or `nil`
    /// when no camera is connected.
    static func captureDevice(for deviceID: String?) -> AVCaptureDevice? {
        if let deviceID, !deviceID.isEmpty, let device = AVCaptureDevice(uniqueID: deviceID) { return device }
        if let preferred = AVCaptureDevice.systemPreferredCamera { return preferred }
        if let fallback = AVCaptureDevice.default(for: .video) { return fallback }
        return AVCaptureDevice.DiscoverySession(deviceTypes: deviceTypes, mediaType: .video, position: .unspecified).devices.first
    }
}

/// Observable camera list for the HUD camera menu and the Camera settings
/// section. Updates on connect / disconnect; `refresh()` re-reads on demand.
@Observable
final class CameraDevices {
    static let shared = CameraDevices()

    private(set) var list: CameraDeviceList
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var devices: [CameraDevice] { list.devices }
    var defaultDevice: CameraDevice? { list.defaultDevice }
    /// Drives `RecordingHUDToggle.camera.isAvailable` (R4.I).
    var hasCamera: Bool { !list.isEmpty }

    /// Called after every change (besides Observation).
    @ObservationIgnored var onChange: ((CameraDeviceList) -> Void)?

    init(startObserving: Bool = true) {
        list = CameraDeviceList.current()
        guard startObserving else { return }
        let center = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func refresh() {
        let fresh = CameraDeviceList.current()
        guard fresh != list else { return }
        list = fresh
        Log.camera.notice("cameras: \(fresh.devices.count) device(s), default \(fresh.defaultDeviceID ?? "none", privacy: .public)")
        onChange?(fresh)
    }
}
