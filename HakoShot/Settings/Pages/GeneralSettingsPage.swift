import AppKit
import HakoKit
import SwiftUI

/// Settings > General (plan §5.3).
struct GeneralSettingsPage: View {
    @AppStorage(.showMenuBarIcon) private var showMenuBarIcon: Bool
    @AppStorage(.playShutterSound) private var playShutterSound: Bool
    @AppStorage(.hideDesktopIconsWhileCapturing) private var hideDesktopIcons: Bool
    @AppStorage(.outputSaveFolderPath) private var saveFolderPath: String

    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.general.title) {
            SettingsCard("Startup") {
                SettingsRow("Launch at login", description: launchAtLoginDescription) {
                    HStack(spacing: Tokens.Spacing.s) {
                        if launchAtLogin.requiresApproval {
                            Button("Open Login Items…") { launchAtLogin.openLoginItemsSettings() }
                        }
                        Toggle("Launch at login", isOn: launchAtLoginBinding)
                            .toggleStyle(.switch)
                    }
                }
                SettingsRow(
                    "Show menu bar icon",
                    description: "When hidden, open HakoShot again from Finder or Spotlight to get back to Settings. Shortcuts keep working."
                ) {
                    Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard("Capture") {
                SettingsRow("Play sounds", description: "Camera shutter sound after every capture.") {
                    Toggle("Play sounds", isOn: $playShutterSound)
                        .toggleStyle(.switch)
                }
                SettingsRow(
                    "Hide desktop icons while capturing",
                    description: "Leave desktop icons and widgets out of every screenshot."
                ) {
                    Toggle("Hide desktop icons while capturing", isOn: $hideDesktopIcons)
                        .toggleStyle(.switch)
                }
            }

            // After capture (plan §5.3, §5.4; kayit-teknik-plan §4.15): one
            // checkbox column for screenshots, one for recordings (CleanShot
            // `settings2.png`); "—" where an action doesn't apply.
            SettingsCard("After capture") {
                AfterCaptureMatrixHeader()
                ForEach(AfterCaptureMatrixRow.rows) { row in
                    SettingsRow(row.title, description: row.description) {
                        HStack(spacing: 0) {
                            AfterCaptureMatrixCell(key: row.screenshot, label: "\(row.title), screenshots")
                            AfterCaptureMatrixCell(key: row.recording, label: "\(row.title), recordings")
                        }
                    }
                }
            }

            SettingsCard("Export") {
                SettingsRow("Export location", description: displayPath) {
                    HStack(spacing: Tokens.Spacing.s) {
                        Button("Show in Finder", action: showFolder)
                        Button("Choose…", action: chooseFolder)
                    }
                }
            }
        }
        .onAppear { launchAtLogin.refresh() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin.isEnabled }, set: { launchAtLogin.setEnabled($0) })
    }

    private var launchAtLoginDescription: String {
        if let error = launchAtLogin.lastError { return error }
        if launchAtLogin.requiresApproval { return "Allow HakoShot in System Settings > General > Login Items." }
        return "Start HakoShot in the menu bar when you log in."
    }

    private var folderURL: URL {
        URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    private var displayPath: String {
        (saveFolderPath as NSString).abbreviatingWithTildeInPath
    }

    private func showFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = folderURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolderPath = url.path
    }
}

/// One line of Settings › General › After capture (tested): which setting
/// each column writes; `nil` = the action doesn't apply ("—").
struct AfterCaptureMatrixRow: Identifiable {
    let title: String
    var description: String?
    let screenshot: SettingsKey<Bool>?
    let recording: SettingsKey<Bool>?

    var id: String { title }

    /// Screenshot: Quick Access on, the rest off (plan §5.4). Recording:
    /// Quick Access on; Copy, Save, Open Video Editor off (plan §5.1).
    static let rows: [AfterCaptureMatrixRow] = [
        AfterCaptureMatrixRow(
            title: "Show Quick Access Overlay",
            description: "Save from the overlay, or automatically when it closes.",
            screenshot: .afterCaptureShowQuickAccess, recording: .afterRecordingShowQuickAccess
        ),
        AfterCaptureMatrixRow(
            title: "Copy file to clipboard",
            screenshot: .outputCopyToClipboardOnCapture, recording: .afterRecordingCopy
        ),
        AfterCaptureMatrixRow(
            title: "Save",
            description: "Write the file to the export location right away.",
            screenshot: .outputSaveToDiskOnCapture, recording: .afterRecordingSave
        ),
        AfterCaptureMatrixRow(
            title: "Open Annotate tool",
            description: "Open every screenshot in the editor.",
            screenshot: .afterCaptureOpenEditor, recording: nil
        ),
        AfterCaptureMatrixRow(title: "Pin to the screen", screenshot: .afterCapturePin, recording: nil),
        AfterCaptureMatrixRow(
            title: "Open Video Editor",
            description: "Open every recording in the video editor.",
            screenshot: nil, recording: .afterRecordingOpenVideoEditor
        ),
    ]
}

private enum AfterCaptureMatrixMetrics {
    /// Width of each checkbox column (fits "Screenshot").
    static let columnWidth: CGFloat = 84
}

/// Column titles above the checkboxes.
private struct AfterCaptureMatrixHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            ForEach(["Screenshot", "Recording"], id: \.self) { title in
                Text(title)
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .frame(width: AfterCaptureMatrixMetrics.columnWidth)
            }
        }
        .padding(.vertical, Tokens.Spacing.s)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
        .accessibilityHidden(true)
    }
}

/// A checkbox bound to `key`, or "—" when the column doesn't apply.
private struct AfterCaptureMatrixCell: View {
    let key: SettingsKey<Bool>?
    let label: String

    var body: some View {
        Group {
            if let key {
                AfterCaptureCheckbox(key: key, label: label)
            } else {
                Text("—")
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .accessibilityLabel("\(label): not available")
            }
        }
        .frame(width: AfterCaptureMatrixMetrics.columnWidth)
    }
}

private struct AfterCaptureCheckbox: View {
    @AppStorage private var isOn: Bool
    let label: String

    init(key: SettingsKey<Bool>, label: String) {
        _isOn = AppStorage(key)
        self.label = label
    }

    var body: some View {
        Toggle(label, isOn: $isOn)
            .toggleStyle(.checkbox)
            .labelsHidden()
    }
}
