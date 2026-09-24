import AppKit
import HakoKit
import SwiftUI

/// Right-hand inspector (plan §4.19): icon tabs, one page per section.
struct StudioInspectorView: View {
    @Bindable var model: StudioViewModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.inspectorTab) {
                ForEach(StudioInspectorTab.allCases) { tab in
                    Image(systemName: tab.symbol)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Tokens.Spacing.m)
            Divider()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    Text(model.inspectorTab.title)
                        .font(.system(size: 13, weight: .semibold))
                    page
                }
                .padding(Tokens.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var page: some View {
        switch model.inspectorTab {
        case .background: BackgroundInspector(model: model)
        case .cursor: CursorInspector(model: model)
        case .zoom: ZoomInspector(model: model)
        case .motionBlur: MotionBlurInspector(model: model)
        case .camera: CameraInspector(model: model)
        case .keys: KeystrokesInspector(model: model)
        case .audio: AudioInspector(model: model)
        }
    }
}

// MARK: - Shared controls

/// Titled group of inspector rows.
struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            content
        }
    }
}

/// Labeled slider; one drag is one undo step (`beginInteraction`).
struct InspectorSlider: View {
    let model: StudioViewModel
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    let set: @MainActor (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(format(value))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            Slider(
                value: Binding(get: { value }, set: { v in
                    let stepped = step.map { (v / $0).rounded() * $0 } ?? v
                    set(min(max(stepped, range.lowerBound), range.upperBound))
                }),
                in: range
            ) { editing in
                if editing { model.beginInteraction(title) } else { model.endInteraction() }
            }
            .controlSize(.small)
        }
    }
}

/// Toggle row writing one action.
struct InspectorToggle: View {
    let title: String
    let isOn: Bool
    let set: @MainActor (Bool) -> Void

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { value in set(value) }))
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.system(size: 12))
    }
}

/// Grey explanation under disabled controls.
struct InspectorNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            .fixedSize(horizontal: false, vertical: true)
    }
}

nonisolated enum InspectorFormat {
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded())) %" }
    static func points(_ v: Double) -> String { "\(Int(v.rounded())) pt" }
    static func scale(_ v: Double) -> String { String(format: "%.1f×", v) }
    static func seconds(_ v: Double) -> String { String(format: "%.1f s", v) }
}
