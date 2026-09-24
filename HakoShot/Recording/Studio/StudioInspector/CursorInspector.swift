import HakoKit
import SwiftUI

/// Cursor tab (plan §4.20): visible, size, smoothing, hide when idle, click
/// effect. Inert when the cursor is part of the video pixels (classic
/// recording opened in Studio).
struct CursorInspector: View {
    let model: StudioViewModel

    private var cursor: StudioCursorSettings { model.project.cursor }
    private var editable: Bool { model.project.supportsCursorEditing }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if !editable {
                InspectorNote(text: "This video was recorded with the cursor drawn into it, so the cursor can't be resized, smoothed or hidden. Zoom and background still apply. Record in Studio Mode to edit the cursor.")
            }
            Group {
                InspectorToggle(title: "Show cursor", isOn: cursor.visible) { model.apply(.setCursorVisible($0)) }
                InspectorSlider(model: model, title: "Size", value: cursor.scale, range: StudioCursorSettings.scaleRange, step: 0.1,
                                format: InspectorFormat.scale) { model.apply(.setCursorScale($0)) }
                    .disabled(!cursor.visible)
                InspectorSlider(model: model, title: "Smoothing", value: cursor.smoothing, range: 0...1, step: 0.01,
                                format: InspectorFormat.percent) { model.apply(.setCursorSmoothing($0)) }
                    .disabled(!cursor.visible)
                InspectorToggle(title: "Hide when idle", isOn: cursor.hideWhenIdle) { model.apply(.setHideCursorWhenIdle($0)) }
                    .disabled(!cursor.visible)
                if cursor.hideWhenIdle {
                    InspectorSlider(model: model, title: "Idle delay", value: cursor.idleDelay, range: 0.5...10, step: 0.5,
                                    format: InspectorFormat.seconds) { v in
                        var c = cursor
                        c.idleDelay = v
                        model.apply(.setCursor(c))
                    }
                }
                Picker("Style", selection: Binding(get: { cursor.style }, set: { style in
                    var c = cursor
                    c.style = style
                    model.apply(.setCursor(c))
                })) {
                    Text("Recorded").tag(StudioCursorStyle.system)
                    Text("Arrow").tag(StudioCursorStyle.arrow)
                }
                .pickerStyle(.segmented)
                .font(.system(size: 12))
                Divider()
                InspectorToggle(title: "Click effect", isOn: cursor.clickEffect) { model.apply(.setClickEffect($0)) }
            }
            .disabled(!editable)
            .opacity(editable ? 1 : 0.5)
        }
    }
}
