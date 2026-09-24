import AppKit
import SwiftUI

/// "Set up Do Not Disturb…" (plan §4.11, DND layer 2): explains how to make
/// the two Shortcuts that turn Focus on and off, and stores their names in
/// `recordingFocusOnShortcut` / `recordingFocusOffShortcut`. Notifications
/// are kept out of the recording either way (layer 1).
///
/// Present with `.sheet(isPresented:) { DoNotDisturbSetupSheet() }` from the
/// Recording settings page.
struct DoNotDisturbSetupSheet: View {
    static let suggestedOnName = "HakoShot Focus On"
    static let suggestedOffName = "HakoShot Focus Off"

    @AppStorage(.recordingFocusOnShortcut) private var focusOn: String
    @AppStorage(.recordingFocusOffShortcut) private var focusOff: String
    @AppStorage(.recordingFocusShortcutWarningShown) private var warningShown: Bool
    @Environment(\.dismiss) private var dismiss

    @State private var installed: [String] = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("Do Not Disturb While Recording")
                    .font(Tokens.Typography.sectionHeader)
                Text("Notifications are always kept out of the video. To also silence them on screen, HakoShot can run two shortcuts that turn Focus on and off.")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard("In the Shortcuts app") {
                step(1, "Create a shortcut named “\(Self.suggestedOnName)” with the action Set Focus → Do Not Disturb → Turn On.")
                step(2, "Create a shortcut named “\(Self.suggestedOffName)” with Set Focus → Do Not Disturb → Turn Off.")
                step(3, "Choose them below. The first run may ask for permission.")
            }

            SettingsCard("Shortcuts") {
                SettingsRow("Turn Focus on", description: "Runs when recording starts.") {
                    nameField(text: $focusOn, suggestion: Self.suggestedOnName)
                }
                SettingsRow("Turn Focus off", description: "Runs when recording ends.") {
                    nameField(text: $focusOff, suggestion: Self.suggestedOffName)
                }
            }

            HStack(spacing: Tokens.Spacing.s) {
                Button("Open Shortcuts") { Self.openShortcutsApp() }
                Button("Refresh") { Task { await loadShortcuts() } }
                    .disabled(isLoading)
                if isLoading { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: Tokens.Recording.dndSetupSheetWidth)
        .task { await loadShortcuts() }
        .onChange(of: focusOn) { warningShown = false }
        .onChange(of: focusOff) { warningShown = false }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.m) {
            Text("\(number)")
                .font(Tokens.Typography.hudLabel.weight(.semibold))
                .foregroundStyle(Color.white)
                .frame(width: Tokens.Recording.dndSetupStepBadge, height: Tokens.Recording.dndSetupStepBadge)
                .background(Circle().fill(Color.dsAccent))
            Text(text)
                .font(Tokens.Typography.rowLabel)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Tokens.Spacing.settingsRowV)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
    }

    /// Text field + menu of installed shortcuts (from `shortcuts list`).
    private func nameField(text: Binding<String>, suggestion: String) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            TextField(suggestion, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: Tokens.Recording.dndSetupFieldWidth)
            Menu {
                if installed.isEmpty {
                    Text(isLoading ? "Loading…" : "No shortcuts found")
                } else {
                    ForEach(installed, id: \.self) { name in
                        Button(name) { text.wrappedValue = name }
                    }
                }
                Divider()
                Button("None") { text.wrappedValue = "" }
            } label: {
                Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private func loadShortcuts() async {
        isLoading = true
        installed = await ShellShortcutRunner.listShortcuts()
        isLoading = false
    }

    static func openShortcutsApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
