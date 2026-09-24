import HakoKit
import SwiftUI

/// Keys tab (plan §4.9, §4.19): the keystroke badge in the Studio render —
/// show, position, size, style, filter. Inert when the recording has no
/// key events (keystrokes were off while recording).
struct KeystrokesInspector: View {
    let model: StudioViewModel

    private var keys: StudioKeystrokeSettings { model.project.keystrokes }
    private var hasKeys: Bool { !(model.metadata?.keys.isEmpty ?? true) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if !hasKeys {
                InspectorNote(text: "This recording has no key presses. Turn on \"Show keystrokes\" in the recording options before recording in Studio Mode.")
            }
            Group {
                InspectorToggle(title: "Show keystrokes", isOn: keys.visible) { v in update { $0.visible = v } }
                Group {
                    Picker("Position", selection: Binding(get: { keys.placement }, set: { v in update { $0.placement = v } })) {
                        Text("Bottom center").tag(KeystrokeBadgePlacement.bottomCenter)
                        Text("Bottom left").tag(KeystrokeBadgePlacement.bottomLeft)
                        Text("Bottom right").tag(KeystrokeBadgePlacement.bottomRight)
                        Text("Top center").tag(KeystrokeBadgePlacement.topCenter)
                    }
                    Picker("Size", selection: Binding(get: { keys.badgeSize }, set: { v in update { $0.badgeSize = v } })) {
                        Text("Small").tag(RecordingOverlaySize.small)
                        Text("Medium").tag(RecordingOverlaySize.medium)
                        Text("Large").tag(RecordingOverlaySize.large)
                    }
                    .pickerStyle(.segmented)
                    Picker("Style", selection: Binding(get: { keys.isLight }, set: { v in update { $0.isLight = v } })) {
                        Text("Dark").tag(false)
                        Text("Light").tag(true)
                    }
                    .pickerStyle(.segmented)
                    Picker("Show", selection: Binding(get: { keys.displayFilter }, set: { v in update { $0.displayFilter = v } })) {
                        Text("All recorded keys").tag(KeystrokeDisplayFilter.allKeys)
                        Text("Shortcuts only").tag(KeystrokeDisplayFilter.shortcutsOnly)
                    }
                    InspectorNote(text: "Only keys captured while recording can be shown.")
                }
                .disabled(!keys.visible)
            }
            .font(.system(size: 12))
            .disabled(!hasKeys)
            .opacity(hasKeys ? 1 : 0.5)
        }
    }

    /// One `.setKeystrokes` with `change` applied.
    private func update(_ change: (inout StudioKeystrokeSettings) -> Void) {
        var k = keys
        change(&k)
        model.apply(.setKeystrokes(k))
    }
}
