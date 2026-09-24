import AppKit
import KeyboardShortcuts
import SwiftUI

/// Settings > Shortcuts (plan §5.3, WP7.1): every global command from
/// `ShortcutBinding.all`, grouped as Capture, Text and Tools, a
/// search field, `ShortcutRecorderPill`s, inline duplicate warnings and a
/// banner when macOS's own screenshot shortcuts still own a HakoShot combo.
struct ShortcutsSettingsPage: View {
    @State private var model = ShortcutsSettingsModel()
    @State private var query = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.cardGap) {
                header
                if !model.systemConflicts.isEmpty {
                    SystemShortcutsBanner(conflicts: model.systemConflicts)
                }
                let groups = filteredGroups
                if groups.isEmpty {
                    Text("No shortcuts match “\(query)”.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, Tokens.Spacing.xl)
                }
                ForEach(groups, id: \.group) { entry in
                    SettingsCard(entry.group.rawValue) {
                        ForEach(entry.bindings) { binding in
                            ShortcutRow(binding: binding, model: model)
                        }
                    }
                }
                if query.isEmpty {
                    systemCard
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { model.resetAll() }
                            .controlSize(.regular)
                    }
                }
            }
            .padding(SettingsMetrics.pagePadding)
            .padding(.top, SettingsMetrics.pagePadding) // clear the transparent titlebar
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.activate() }
        .onDisappear { model.deactivate() }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text(SettingsPage.shortcuts.title)
                .font(Tokens.Typography.settingsTitle)
            Spacer(minLength: Tokens.Spacing.l)
            SearchPill(text: $query)
        }
        .padding(.top, SettingsMetrics.titleTopPadding)
    }

    /// "macOS screenshot shortcuts" card: state of the five system hotkeys + link.
    private var systemCard: some View {
        SettingsCard("macOS Screenshot Shortcuts") {
            SettingsRow(
                "System screenshot shortcuts",
                description: systemSummary
            ) {
                Button("Open Keyboard Settings") { openKeyboardSettings() }
            }
        }
    }

    private var systemSummary: String {
        let enabled = model.systemShortcuts.filter(\.isEnabled)
        if enabled.isEmpty {
            return "Off. HakoShot receives ⇧⌘3, ⇧⌘4 and ⇧⌘5."
        }
        let combos = enabled.map { ShortcutLabel.text(for: $0.combo) }.joined(separator: ", ")
        return "On for \(combos). macOS handles these before HakoShot; turn them off under Keyboard Shortcuts › Screenshots to use them here."
    }

    private var filteredGroups: [(group: ShortcutGroup, bindings: [ShortcutBinding])] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ShortcutGroup.allCases.compactMap { group in
            let bindings = ShortcutBinding.all.filter { binding in
                guard binding.group == group else { return false }
                guard !needle.isEmpty else { return true }
                return binding.title.lowercased().contains(needle)
                    || group.rawValue.lowercased().contains(needle)
                    || (model.label(for: binding)?.lowercased().contains(needle) ?? false)
            }
            return bindings.isEmpty ? nil : (group, bindings)
        }
    }
}

/// Opens System Settings › Keyboard.
@MainActor
func openKeyboardSettings() {
    guard let url = ShortcutConflictDetector.keyboardSettingsURL else { return }
    NSWorkspace.shared.open(url)
}

/// One command: title (+ warning line) and its recorder pill.
private struct ShortcutRow: View {
    let binding: ShortcutBinding
    let model: ShortcutsSettingsModel

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.settingsRowTextGap) {
                Text(binding.title)
                    .font(Tokens.Typography.rowLabel)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
                if let warning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .fixedSize(horizontal: false, vertical: true)
                } else if model.isRecording(binding), let rejection = model.rejection {
                    Text(rejection)
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: .systemRed))
                } else if model.isRecording(binding) {
                    Text("Press the new shortcut. Esc cancels, ⌫ clears.")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ShortcutRecorderPill(binding: binding, model: model)
        }
        .padding(.vertical, Tokens.Spacing.settingsRowV)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
        .accessibilityElement(children: .contain)
    }

    private var warning: String? {
        let duplicates = model.duplicateTitles(for: binding)
        if !duplicates.isEmpty {
            return "Also used by \(ListFormatter.localizedString(byJoining: duplicates)). Both run."
        }
        if model.systemConflict(for: binding) != nil {
            return "macOS uses this shortcut for screenshots, so HakoShot won't receive it."
        }
        return nil
    }
}

/// Yellow notice: macOS screenshot shortcuts still enabled for HakoShot combos.
private struct SystemShortcutsBanner: View {
    let conflicts: [SystemShortcutConflict]

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color(nsColor: .systemYellow))
                .symbolRenderingMode(.multicolor)
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("macOS screenshot shortcuts are on")
                    .font(Tokens.Typography.sectionHeader)
                Text(message)
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Keyboard Settings") { openKeyboardSettings() }
                    .padding(.top, Tokens.Spacing.xxs)
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.Spacing.settingsRowH)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                .fill(Color(nsColor: .systemYellow).opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.settingsCard, style: .continuous)
                        .strokeBorder(Color(nsColor: .systemYellow).opacity(0.45), lineWidth: Tokens.Stroke.hairline)
                }
        }
    }

    private var message: String {
        let combos = conflicts.map { ShortcutLabel.text(for: $0.system.combo) }
        var seen = Set<String>()
        let unique = combos.filter { seen.insert($0).inserted }
        return "\(ListFormatter.localizedString(byJoining: unique)) \(unique.count == 1 ? "is" : "are") taken by macOS, "
            + "so the HakoShot shortcuts on them won't work. In Keyboard Shortcuts › Screenshots, turn off the ones you want HakoShot to handle."
    }
}

/// Capsule search field for the page header (report §12: magnifier + placeholder).
private struct SearchPill: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .frame(width: 200, height: 28)
        .background {
            Capsule().fill(Color(nsColor: Tokens.Palette.neutralPillFill))
                .overlay {
                    Capsule().strokeBorder(focused ? Color.dsAccent.opacity(0.6) : .clear, lineWidth: 1.5)
                }
        }
    }
}

/// "⇧⌘4" for a combo that isn't (necessarily) a stored shortcut.
enum ShortcutLabel {
    static func text(for combo: ShortcutCombo) -> String {
        KeyboardShortcuts.Shortcut(carbonKeyCode: combo.keyCode, carbonModifiers: combo.carbonModifiers).description
    }
}
