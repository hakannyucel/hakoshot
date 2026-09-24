import AppKit
import SwiftUI

/// Settings > Screen Recording > "Camera" (plan §4.21 "Camera", §4.8; a
/// HakoShot addition — `reports/cleanshot-recording-settings-ui.md` §1.7):
/// camera device, Shape, Size, Corner, Mirror, plus the Camera permission
/// row. Own view type because an extension can't add the `@AppStorage` /
/// `@State` it needs to `RecordingSettingsPage`.
extension RecordingSettingsPage {
    var cameraSection: some View {
        CameraSettingsSection()
    }
}

struct CameraSettingsSection: View {
    @AppStorage(.recordingCameraDeviceID) private var deviceID: String
    @AppStorage(.recordingCameraShape) private var shape: CameraShape
    @AppStorage(.recordingCameraSize) private var size: RecordingElementSize
    @AppStorage(.recordingCameraCorner) private var corner: CameraCorner
    @AppStorage(.recordingCameraMirror) private var mirror: Bool

    @State private var devices = CameraDevices.shared
    @State private var permission = CameraPermission.status

    var body: some View {
        SettingsCard("Camera") {
            SettingsRow("Camera", description: "Turn the camera on from the recording toolbar.") {
                Picker("Camera", selection: $deviceID) {
                    ForEach(Self.pickerOptions(devices: devices.list, selectedID: deviceID), id: \.id) { option in
                        Text(option.title).tag(option.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: Tokens.Recording.settingsDevicePickerMaxWidth)
            }
            SettingsRow("Shape") {
                Picker("Shape", selection: $shape) {
                    ForEach(CameraShape.allCases, id: \.self) { shape in
                        Text(shape.optionTitle).tag(shape)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Size") {
                Picker("Size", selection: $size) {
                    ForEach(RecordingElementSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Position", description: "Drag the bubble while recording; it snaps to the nearest corner.") {
                Picker("Position", selection: $corner) {
                    ForEach(CameraCorner.allCases, id: \.self) { corner in
                        Text(corner.optionTitle).tag(corner)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsRow("Mirror camera", description: "Flips the camera horizontally, like a mirror.") {
                Toggle("Mirror camera", isOn: $mirror).toggleStyle(.switch)
            }
            SettingsRow("Camera access", description: "Double-click the bubble while recording to show the camera full size.") {
                HStack(spacing: Tokens.Spacing.s) {
                    Label(permission.isGranted ? "Granted" : "Not granted",
                          systemImage: permission.isGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(permission.isGranted ? Color.green : Color.orange)
                        .font(Tokens.Typography.rowLabel)
                    if !permission.isGranted {
                        Button("Grant…") {
                            Task {
                                if permission.needsSystemSettings {
                                    CameraPermission.openSystemSettings()
                                } else {
                                    _ = await CameraPermission.request()
                                }
                                permission = CameraPermission.status
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            devices.refresh()
            permission = CameraPermission.status
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permission = CameraPermission.status
        }
    }

    struct PickerOption: Equatable {
        var id: String
        var title: String
    }

    /// "Default (<name>)" first (id ""), then every camera; a saved camera
    /// that is disconnected stays listed as "(not connected)" so the picker
    /// keeps a valid selection.
    static func pickerOptions(devices: CameraDeviceList, selectedID: String) -> [PickerOption] {
        let defaultTitle = devices.defaultDevice.map { "Default (\($0.name))" } ?? "Default"
        var options = [PickerOption(id: "", title: defaultTitle)]
        options += devices.devices.map { PickerOption(id: $0.id, title: $0.name) }
        if !selectedID.isEmpty, !devices.devices.contains(where: { $0.id == selectedID }) {
            options.append(PickerOption(id: selectedID, title: "Unavailable camera (not connected)"))
        }
        return options
    }
}

extension CameraShape {
    var optionTitle: String {
        switch self {
        case .squircle: "Squircle"
        case .circle: "Circle"
        case .rectangle: "Rectangle (16:9)"
        case .vertical: "Vertical (9:16)"
        }
    }
}

extension CameraCorner {
    var optionTitle: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }
}
