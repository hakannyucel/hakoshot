@preconcurrency import AVFoundation
import Foundation
import os
import Observation

/// One audio input device (plan §1.4).
nonisolated struct MicrophoneDevice: Sendable, Equatable, Hashable, Identifiable, Codable {
    /// `AVCaptureDevice.uniqueID` (`MicrophoneChoice.device(uniqueID:)`,
    /// `SCStreamConfiguration.microphoneCaptureDeviceID`).
    var id: String
    var name: String
    /// `.microphone` (built-in / USB class) or `.external`.
    var isExternal: Bool
}

/// A snapshot of the input devices and the system default input.
nonisolated struct MicrophoneDeviceList: Sendable, Equatable, Codable {
    var devices: [MicrophoneDevice]
    /// The system default input's ID (`AVCaptureDevice.default(for: .audio)`).
    var defaultDeviceID: String?

    static let empty = MicrophoneDeviceList(devices: [], defaultDeviceID: nil)

    var defaultDevice: MicrophoneDevice? {
        defaultDeviceID.flatMap { id in devices.first { $0.id == id } }
    }

    /// The device a choice records from: the chosen device if it is still
    /// connected, otherwise the system default (a disconnected device falls
    /// back instead of failing the recording).
    func resolve(_ choice: MicrophoneChoice) -> MicrophoneDevice? {
        switch choice {
        case .systemDefault:
            return defaultDevice ?? devices.first
        case let .device(uniqueID):
            return devices.first { $0.id == uniqueID } ?? defaultDevice ?? devices.first
        }
    }

    /// `SCStreamConfiguration.microphoneCaptureDeviceID` for a choice: `nil`
    /// = let the system pick its default input.
    func captureDeviceID(for choice: MicrophoneChoice) -> String? {
        guard case let .device(uniqueID) = choice, devices.contains(where: { $0.id == uniqueID }) else { return nil }
        return uniqueID
    }

    /// Reads the connected input devices (no TCC prompt: listing devices
    /// does not open them).
    static func current() -> MicrophoneDeviceList {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = session.devices.map {
            MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName, isExternal: $0.deviceType == .external)
        }
        return MicrophoneDeviceList(devices: devices, defaultDeviceID: AVCaptureDevice.default(for: .audio)?.uniqueID)
    }
}

/// Observable list of audio input devices for the HUD mic menu and the
/// Audio settings section (plan §1.4). Updates on device connect /
/// disconnect notifications; `refresh()` re-reads on demand (e.g. when the
/// menu opens, since a default-input change posts no notification).
@Observable
final class MicrophoneDevices {
    static let shared = MicrophoneDevices()

    private(set) var list: MicrophoneDeviceList
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    var devices: [MicrophoneDevice] { list.devices }
    var defaultDevice: MicrophoneDevice? { list.defaultDevice }

    /// Called after every change (besides Observation).
    @ObservationIgnored var onChange: ((MicrophoneDeviceList) -> Void)?

    init(startObserving: Bool = true) {
        list = MicrophoneDeviceList.current()
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
        let fresh = MicrophoneDeviceList.current()
        guard fresh != list else { return }
        list = fresh
        Log.recording.notice("microphones: \(fresh.devices.count) device(s), default \(fresh.defaultDeviceID ?? "none", privacy: .public)")
        onChange?(fresh)
    }
}

/// One row of a microphone picker (HUD mic menu, Settings > Audio).
nonisolated struct MicrophoneMenuOption: Sendable, Equatable, Identifiable {
    /// `recordingMicrophoneDeviceID` value; "" = System Default.
    var id: String
    var title: String
    /// `false` for a saved device that is not connected (recording falls back to the default).
    var isConnected: Bool
}

extension MicrophoneDeviceList {
    /// "System Default (<name>)" first (id ""), then every device; a saved
    /// device that is disconnected stays listed as "(not connected)" so the
    /// selection stays visible.
    nonisolated func menuOptions(selectedID: String) -> [MicrophoneMenuOption] {
        let defaultTitle = defaultDevice.map { "System Default (\($0.name))" } ?? "System Default"
        var options = [MicrophoneMenuOption(id: "", title: defaultTitle, isConnected: true)]
        options += devices.map { MicrophoneMenuOption(id: $0.id, title: $0.name, isConnected: true) }
        if !selectedID.isEmpty, !devices.contains(where: { $0.id == selectedID }) {
            options.append(MicrophoneMenuOption(id: selectedID, title: "Saved microphone (not connected)", isConnected: false))
        }
        return options
    }
}
