import AppKit
import CoreGraphics
import SwiftUI

/// Settings > Screen Recording > "Keystrokes" (plan §4.21 "Keystrokes",
/// §4.9; `reports/cleanshot-recording-settings-ui.md` §1.3): "Show
/// keystrokes" toggle + "Options…" popover (position, size, Dark/Light
/// style, Shortcuts only / All keys) and the Input Monitoring permission row.
/// Own view type because an extension can't add the `@AppStorage` / `@State`
/// it needs to `RecordingSettingsPage`.
extension RecordingSettingsPage {
    var keystrokesSection: some View {
        KeystrokesSettingsSection()
    }
}

struct KeystrokesSettingsSection: View {
    @AppStorage(.recordingShowKeystrokes) private var showKeystrokes: Bool
    @State private var showsOptions = false
    @State private var inputMonitoringGranted = KeystrokesInputMonitoring.isGranted

    var body: some View {
        SettingsCard("Keystrokes") {
            SettingsRow("Show keystrokes", description: "Shows the shortcuts you press as a badge in the recording.") {
                HStack(spacing: Tokens.Spacing.s) {
                    Button("Options…") { showsOptions = true }
                        .disabled(!showKeystrokes)
                        .popover(isPresented: $showsOptions, arrowEdge: .top) {
                            KeystrokeOptionsPopover()
                        }
                    Toggle("Show keystrokes", isOn: $showKeystrokes).toggleStyle(.switch)
                }
            }
            SettingsRow("Input Monitoring", description: Self.permissionNote) {
                HStack(spacing: Tokens.Spacing.s) {
                    Label(inputMonitoringGranted ? "Granted" : "Not granted",
                          systemImage: inputMonitoringGranted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(inputMonitoringGranted ? Color.green : Color.orange)
                        .font(Tokens.Typography.rowLabel)
                    if !inputMonitoringGranted {
                        Button("Grant…") {
                            if !KeystrokesInputMonitoring.request() { KeystrokesInputMonitoring.openSystemSettings() }
                            inputMonitoringGranted = KeystrokesInputMonitoring.isGranted
                        }
                    }
                }
            }
        }
        .onAppear { inputMonitoringGranted = KeystrokesInputMonitoring.isGranted }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoringGranted = KeystrokesInputMonitoring.isGranted
        }
    }

    static let permissionNote = "Showing keystrokes requires Input Monitoring permission. Password fields are never shown."
}

/// "Show keystrokes" Options… popover (CleanShot `/features` text: position,
/// size, Dark/Light style, all keys or shortcuts only — the popover itself
/// wasn't visually verified, report §1.3).
struct KeystrokeOptionsPopover: View {
    @AppStorage(.recordingKeystrokePosition) private var position: KeystrokeBadgePosition
    @AppStorage(.recordingKeystrokeSize) private var size: RecordingElementSize
    @AppStorage(.recordingKeystrokeStyle) private var style: KeystrokeBadgeStyle
    @AppStorage(.recordingKeystrokeFilter) private var filter: KeystrokeFilter

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("Keystrokes")
                .font(Tokens.Typography.sectionHeader)

            HStack {
                Text("Position")
                Spacer(minLength: Tokens.Spacing.m)
                Picker("Position", selection: $position) {
                    ForEach(KeystrokeBadgePosition.allCases, id: \.self) { position in
                        Text(position.optionTitle).tag(position)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Size")
                Spacer(minLength: Tokens.Spacing.m)
                Picker("Size", selection: $size) {
                    ForEach(RecordingElementSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Style")
                Spacer(minLength: Tokens.Spacing.m)
                Picker("Style", selection: $style) {
                    ForEach(KeystrokeBadgeStyle.allCases, id: \.self) { style in
                        Text(style.optionTitle).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Picker("Show", selection: $filter) {
                    ForEach(KeystrokeFilter.allCases, id: \.self) { filter in
                        Text(filter.optionTitle).tag(filter)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Shortcuts only: key combinations with ⌘, ⌃ or ⌥, plus Esc, Return, Tab, Delete, arrows and F-keys.")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 280)
    }
}

extension KeystrokeBadgePosition {
    var optionTitle: String {
        switch self {
        case .bottomCenter: "Bottom center"
        case .bottomLeft: "Bottom left"
        case .bottomRight: "Bottom right"
        case .topCenter: "Top center"
        }
    }
}

extension KeystrokeBadgeStyle {
    var optionTitle: String {
        switch self {
        case .dark: "Dark"
        case .light: "Light"
        }
    }
}

extension KeystrokeFilter {
    var optionTitle: String {
        switch self {
        case .shortcutsOnly: "Shortcuts only"
        case .allKeys: "All keys"
        }
    }
}

/// Input Monitoring (listen-only event tap, plan §1.6 / §1.8) status for the
/// Settings row. Forwards to `InputMonitoringPermission` (R5.1).
enum KeystrokesInputMonitoring {
    static let paneAnchor = InputMonitoringPermission.paneAnchor

    static var isGranted: Bool { InputMonitoringPermission.isGranted }

    /// Prompts once (adds the app to the list); later calls return the
    /// stored decision without prompting.
    @discardableResult
    static func request() -> Bool { InputMonitoringPermission.request() }

    static func openSystemSettings() { InputMonitoringPermission.openSystemSettings() }
}
