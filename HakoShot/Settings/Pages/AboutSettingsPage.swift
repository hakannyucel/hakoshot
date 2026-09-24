import AppKit
import SwiftUI

/// Settings > About (plan §5.3): version, permission status, data folders.
struct AboutSettingsPage: View {
    @Environment(PermissionsService.self) private var permissions

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.about.title) {
            SettingsCard {
                HStack(spacing: Tokens.Spacing.l) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                        Text("HakoShot").font(.title2.weight(.semibold))
                        Text("Version \(AppInfo.version) (\(AppInfo.build))")
                            .font(Tokens.Typography.rowLabel)
                            .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                            .textSelection(.enabled)
                        Text("Screenshots, annotation and pins for the menu bar.")
                            .font(Tokens.Typography.rowDescription)
                            .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Tokens.Spacing.l)
                .padding(.horizontal, Tokens.Spacing.settingsRowH)
            }

            SettingsCard("Permissions") {
                permissionRow(
                    "Screen Recording",
                    detail: "Needed for every capture. After granting, quit and reopen HakoShot.",
                    granted: permissions.screenRecordingGranted
                ) {
                    if !permissions.requestScreenRecording() { permissions.openSystemSettings(.screenRecording) }
                }
                permissionRow(
                    "Accessibility",
                    detail: "Only for auto-scroll in scrolling captures.",
                    granted: permissions.accessibilityGranted
                ) {
                    if !permissions.requestAccessibility() { permissions.openSystemSettings(.accessibility) }
                }
                SettingsRow(
                    "Permission stuck after an update?",
                    description: "Run “tccutil reset ScreenCapture com.hakanyucel.HakoShot” in Terminal, then reopen HakoShot."
                )
                .textSelection(.enabled)
                SettingsRow("Welcome guide", description: "Permissions, macOS shortcut takeover and launch at login.") {
                    Button("Show Welcome Guide…") {
                        NotificationCenter.default.post(name: .showOnboarding, object: nil)
                    }
                }
            }

            SettingsCard("Data") {
                folderRow("Capture history", url: HistoryStore.defaultRootURL)
                folderRow("Drag cache", url: DragSource.dragDirectory, detail: "Files dragged out of Quick Access; cleared after a day.")
            }
        }
        .onAppear { permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private func permissionRow(_ title: String, detail: String, granted: Bool, grant: @escaping () -> Void) -> some View {
        SettingsRow(title, description: detail) {
            HStack(spacing: Tokens.Spacing.s) {
                Label(granted ? "Granted" : "Not granted", systemImage: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(granted ? Color.green : Color.orange)
                    .font(Tokens.Typography.rowLabel)
                if !granted {
                    Button("Grant…", action: grant)
                }
            }
        }
    }

    private func folderRow(_ title: String, url: URL, detail: String? = nil) -> some View {
        let path = (url.path as NSString).abbreviatingWithTildeInPath
        return SettingsRow(title, description: detail.map { "\(path)\n\($0)" } ?? path) {
            Button("Show in Finder") { show(url) }
        }
    }

    private func show(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }
}
