import AppKit
import SwiftUI

/// Settings > General (plan §5.3).
struct GeneralSettingsPage: View {
    @AppStorage(.showMenuBarIcon) private var showMenuBarIcon: Bool
    @AppStorage(.playShutterSound) private var playShutterSound: Bool
    @AppStorage(.hideDesktopIconsWhileCapturing) private var hideDesktopIcons: Bool

    // After capture (plan §5.3, §5.4): Quick Access on, everything else off.
    @AppStorage(.afterCaptureShowQuickAccess) private var showQuickAccess: Bool
    @AppStorage(.outputCopyToClipboardOnCapture) private var copyToClipboard: Bool
    @AppStorage(.outputSaveToDiskOnCapture) private var saveToDisk: Bool
    @AppStorage(.afterCaptureOpenEditor) private var openEditor: Bool
    @AppStorage(.afterCapturePin) private var pin: Bool
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

            SettingsCard("After capture") {
                checkbox("Show Quick Access Overlay", isOn: $showQuickAccess,
                         description: "Save from the overlay, or automatically when it closes.")
                checkbox("Copy file to clipboard", isOn: $copyToClipboard)
                checkbox("Save", isOn: $saveToDisk, description: "Write the file to the export location right away.")
                checkbox("Open Annotate tool", isOn: $openEditor, description: "Open every capture in the editor.")
                checkbox("Pin to the screen", isOn: $pin)
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

    private func checkbox(_ title: String, isOn: Binding<Bool>, description: String? = nil) -> some View {
        SettingsRow(title, description: description) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.checkbox)
        }
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
