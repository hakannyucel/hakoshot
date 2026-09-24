import HakoKit
import SwiftUI

/// Zoom tab (plan §4.20, R7.2): auto zoom, default scale, transition speed,
/// and the selected segment's scale, focus (follow cursor / fixed point)
/// and easing.
struct ZoomInspector: View {
    let model: StudioViewModel

    private var zoom: StudioZoomSettings { model.project.zoom }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            InspectorSection(title: "Smart Zoom") {
                InspectorToggle(title: "Auto zoom on clicks", isOn: zoom.auto) { model.setAutoZoom($0) }
                InspectorSlider(model: model, title: "Default zoom", value: zoom.defaultScale, range: 1...4, step: 0.1,
                                format: InspectorFormat.scale) { model.apply(.setDefaultZoomScale($0)) }
                Picker("Speed", selection: Binding(get: { zoom.speed }, set: { model.apply(.setZoomSpeed($0)) })) {
                    Text("Slow").tag(StudioZoomSpeed.slow)
                    Text("Normal").tag(StudioZoomSpeed.normal)
                    Text("Fast").tag(StudioZoomSpeed.fast)
                }
                .pickerStyle(.segmented)
                .font(.system(size: 12))
                Button("Regenerate Auto Zooms") { model.regenerateAutoZooms() }
                    .controlSize(.small)
                    .disabled(model.metadata?.clicks.isEmpty ?? true)
                InspectorNote(text: "\(model.zoomSegments.filter { !$0.isManual }.count) auto, \(model.zoomSegments.filter(\.isManual).count) edited. Double-click the zoom lane to add one.")
            }
            Divider()
            if let segment = model.selectedZoom {
                selected(segment)
            } else {
                InspectorNote(text: "Select a zoom in the timeline to change its scale, focus and animation.")
            }
        }
    }

    @ViewBuilder
    private func selected(_ segment: ZoomSegment) -> some View {
        InspectorSection(title: segment.isManual ? "Selected Zoom" : "Selected Zoom (auto)") {
            Text("\(StudioTimeFormat.string(segment.start)) – \(StudioTimeFormat.string(segment.end))")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            InspectorSlider(model: model, title: "Scale", value: segment.scale, range: 1.1...ZoomSegment.scaleRange.upperBound,
                            step: 0.1, format: InspectorFormat.scale) { v in
                model.updateSelectedZoom { $0.scale = v }
            }
            Picker("Focus", selection: Binding(get: { segment.focus == .followCursor }, set: { follow in
                model.updateSelectedZoom { $0.focus = follow ? .followCursor : .fixed(x: 0.5, y: 0.5) }
            })) {
                Text("Follow cursor").tag(true)
                Text("Fixed point").tag(false)
            }
            .pickerStyle(.segmented)
            .font(.system(size: 12))
            if case .fixed(let x, let y) = segment.focus {
                InspectorSlider(model: model, title: "Focus X", value: x, range: 0...1, step: 0.01,
                                format: InspectorFormat.percent) { v in
                    model.updateSelectedZoom { $0.focus = .fixed(x: v, y: y) }
                }
                InspectorSlider(model: model, title: "Focus Y", value: y, range: 0...1, step: 0.01,
                                format: InspectorFormat.percent) { v in
                    model.updateSelectedZoom { $0.focus = .fixed(x: x, y: v) }
                }
            }
            Picker("Animation", selection: Binding(get: { segment.easing }, set: { easing in
                model.updateSelectedZoom { $0.easing = easing }
            })) {
                Text("Smooth").tag(StudioEasing.easeInOutCubic)
                Text("Ease out").tag(StudioEasing.easeOutCubic)
                Text("Linear").tag(StudioEasing.linear)
            }
            .font(.system(size: 12))
            Button(role: .destructive) {
                model.deleteZoom(segment.id)
            } label: {
                Label("Delete Zoom", systemImage: "trash")
            }
            .controlSize(.small)
        }
    }
}
