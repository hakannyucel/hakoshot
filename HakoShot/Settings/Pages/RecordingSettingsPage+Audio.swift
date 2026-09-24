import AppKit
import SwiftUI

/// Settings > Screen Recording > "Audio" (plan §4.21 "Audio", §4.7;
/// `reports/cleanshot-recording-settings-ui.md` §1.5): Record microphone
/// (+ device), Record audio in mono, Record system audio, Audio tracks. The
/// microphone rows are a HakoShot addition (CleanShot picks the device only in
/// the recording toolbar); both write the same settings as the HUD. Own view
/// type because an extension can't add `@AppStorage` / `@State` to
/// `RecordingSettingsPage`.
extension RecordingSettingsPage {
    var audioSection: some View {
        AudioSettingsSection()
    }
}

struct AudioSettingsSection: View {
    @AppStorage(.recordingMicrophoneEnabled) private var microphoneEnabled: Bool
    @AppStorage(.recordingMicrophoneDeviceID) private var microphoneDeviceID: String
    @AppStorage(.recordingMonoAudio) private var monoAudio: Bool
    @AppStorage(.recordingSystemAudio) private var systemAudio: Bool
    @AppStorage(.recordingAudioTracks) private var audioTracks: RecordingAudioTrackLayout

    @State private var devices = MicrophoneDevices.shared
    @State private var access = MediaPermissions.microphone

    var body: some View {
        SettingsCard("Audio") {
            SettingsRow("Record microphone", description: "Also on the recording toolbar.") {
                HStack(spacing: Tokens.Spacing.s) {
                    Picker("Microphone", selection: $microphoneDeviceID) {
                        ForEach(devices.list.menuOptions(selectedID: microphoneDeviceID)) { option in
                            Text(option.title).tag(option.id)
                        }
                    }
                    .labelsHidden()
                    // Long device names truncate instead of squeezing the row title.
                    .frame(maxWidth: Tokens.Recording.settingsDevicePickerMaxWidth)
                    .disabled(!microphoneEnabled)
                    Toggle("Record microphone", isOn: microphoneBinding).toggleStyle(.switch)
                }
            }
            if Self.showsAccessRow(microphoneEnabled: microphoneEnabled, access: access) {
                SettingsRow("Microphone access", description: "Recordings start without the microphone until access is allowed.") {
                    HStack(spacing: Tokens.Spacing.s) {
                        Label("Not allowed", systemImage: "exclamationmark.circle")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(Color.orange)
                            .font(Tokens.Typography.rowLabel)
                        Button(access.needsSystemSettings ? "Open Settings…" : "Allow…") {
                            Task { await requestAccess() }
                        }
                    }
                }
            }
            SettingsRow("Record audio in mono") {
                Toggle("Record audio in mono", isOn: $monoAudio).toggleStyle(.switch)
            }
            SettingsRow("Record system audio", description: "Enable this option to record sound that comes from other applications.") {
                Toggle("Record system audio", isOn: $systemAudio).toggleStyle(.switch)
            }
            SettingsRow(
                "Audio tracks",
                description: "Choose separate tracks to edit the microphone and system audio independently in video editing software."
            ) {
                Picker("Audio tracks", selection: $audioTracks) {
                    ForEach(RecordingAudioTrackLayout.allCases, id: \.self) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .onAppear {
            devices.refresh()
            access = MediaPermissions.microphone
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            access = MediaPermissions.microphone
        }
    }

    /// Turning the microphone on asks for access (the prompt shows once).
    private var microphoneBinding: Binding<Bool> {
        Binding(
            get: { microphoneEnabled },
            set: { isOn in
                microphoneEnabled = isOn
                if isOn, access == .notDetermined { Task { await requestAccess() } }
            }
        )
    }

    private func requestAccess() async {
        if MediaPermissions.microphone.needsSystemSettings {
            PermissionsService.openSystemSettings(.microphone)
        } else {
            _ = await MediaPermissions.requestMicrophone()
        }
        access = MediaPermissions.microphone
    }

    /// The access row shows while the microphone is on and access isn't granted.
    static func showsAccessRow(microphoneEnabled: Bool, access: MediaAuthorization) -> Bool {
        microphoneEnabled && !access.isGranted
    }
}
