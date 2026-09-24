import AppKit
import HakoKit
import SwiftUI

/// Background tool sidebar (report §9.3): Presets… + "+", None, Gradients,
/// Wallpapers, Blurred, Plain color, then Padding / Inset / Auto-balance /
/// Corners / Shadow, Alignment 3×3 and Ratio.
struct BackgroundPanelView: View {
    let model: EditorViewModel

    private var style: DocumentBackgroundStyle? { model.document.background }
    private var shown: DocumentBackgroundStyle { style ?? model.defaultBackgroundStyle }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: EditorMetrics.backgroundSwatchGap), count: EditorMetrics.backgroundSwatchColumns)
    }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    presetsRow
                    noneButton
                    section("Gradients") { gradients }
                    section("Wallpapers") { wallpapers }
                    section("Blurred") { blurred }
                    section("Plain color") { plainColors }
                    Divider()
                    sliders
                    Divider()
                    alignmentAndRatio
                }
                .padding(EditorMetrics.backgroundPanelPadding)
            }
            .scrollIndicators(.automatic)
            Rectangle()
                .fill(Color(nsColor: Tokens.Palette.divider))
                .frame(width: Tokens.Stroke.hairline)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Presets / None

    private var presetsRow: some View {
        HStack(spacing: Tokens.Spacing.s) {
            Menu {
                let presets = model.backgroundPresets
                if presets.isEmpty {
                    Text("No saved presets")
                }
                ForEach(presets) { preset in
                    Button(preset.name) { model.applyBackgroundPreset(preset) }
                }
                if !presets.isEmpty {
                    Divider()
                    Menu("Delete") {
                        ForEach(presets) { preset in
                            Button(preset.name) { model.deleteBackgroundPreset(preset) }
                        }
                    }
                }
            } label: {
                Text("Presets…")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.button)
            .controlSize(.regular)
            Button {
                model.saveBackgroundPreset()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 16, height: 16)
            }
            .disabled(style == nil)
            .help("Save current background as a preset")
        }
    }

    private var noneButton: some View {
        Button {
            model.setBackgroundEnabled(false)
        } label: {
            Text("None")
                .font(.system(size: 12, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: Tokens.Size.pillHeight)
                .background(
                    Capsule(style: .continuous)
                        .fill(style == nil ? Color.accentColor : Color(nsColor: Tokens.Palette.neutralPillFill))
                )
                .foregroundStyle(style == nil ? Color.white : Color(nsColor: Tokens.Palette.textPrimary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("No background")
    }

    // MARK: Fills

    private func isSelected(_ fill: BackgroundFill) -> Bool { style?.fill == fill }

    private var gradients: some View {
        LazyVGrid(columns: columns, spacing: EditorMetrics.backgroundSwatchGap) {
            ForEach(GradientCatalog.gradients) { preset in
                BackgroundSwatch(fill: .preset(preset.id), isSelected: isSelected(.preset(preset.id)), help: preset.name) {
                    model.setBackgroundFill(.preset(preset.id))
                }
            }
        }
    }

    private var wallpapers: some View {
        LazyVGrid(columns: columns, spacing: EditorMetrics.backgroundSwatchGap) {
            if let (id, image) = model.backgroundImageAsset {
                BackgroundSwatch(fill: .image(id), image: image, isSelected: true, help: "Current image") {}
            }
            AddSwatch(symbol: "desktopcomputer", help: "Use desktop picture") {
                model.useDesktopWallpaper(screen: NSApp.keyWindow?.screen)
            }
            AddSwatch(symbol: "plus", help: "Choose image…") {
                model.chooseBackgroundImage(from: NSApp.keyWindow)
            }
        }
    }

    private var blurred: some View {
        LazyVGrid(columns: columns, spacing: EditorMetrics.backgroundSwatchGap) {
            BackgroundSwatch(fill: .blurredScreenshot, image: model.baseImage, isSelected: isSelected(.blurredScreenshot),
                             help: "Blurred screenshot") {
                model.setBackgroundFill(.blurredScreenshot)
            }
            BackgroundSwatch(fill: .transparent, isSelected: isSelected(.transparent), help: "Transparent") {
                model.setBackgroundFill(.transparent)
            }
        }
    }

    private var plainColors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
            ForEach(GradientCatalog.solidColors, id: \.self) { color in
                ColorDot(color: Color(cgColor: color.cgColor), isSelected: isSelected(.solid(color))) {
                    model.setBackgroundFill(.solid(color))
                }
            }
            CustomColorDot(model: model, current: customColor)
        }
    }

    private var customColor: RGBAColor? {
        if case .solid(let color)? = style?.fill, !GradientCatalog.solidColors.contains(color) { return color }
        return nil
    }

    // MARK: Sliders

    private var sliders: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            BackgroundSlider(model: model, title: "Padding", value: shown.padding, range: 0...200, unit: "pt") { v in
                model.updateBackground { $0.padding = v }
            }
            BackgroundSlider(model: model, title: "Inset", value: shown.inset, range: 0...100, unit: "pt") { v in
                model.updateBackground { $0.inset = v }
            }
            Toggle("Auto-balance", isOn: Binding(
                get: { shown.autoBalance },
                set: { on in model.updateBackground { $0.autoBalance = on } }
            ))
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
            BackgroundSlider(model: model, title: "Corners", value: shown.cornerRadius, range: 0...60, unit: "pt") { v in
                model.updateBackground { $0.cornerRadius = v }
            }
            BackgroundSlider(model: model, title: "Shadow", value: shown.shadow.opacity * 100, range: 0...100, unit: "%") { v in
                model.updateBackground { style in
                    // A "none" shadow has no blur; give it the standard shape.
                    if style.shadow.radius == 0 { style.shadow = .standard }
                    style.shadow.opacity = v / 100
                }
            }
        }
        .opacity(style == nil ? 0.5 : 1)
    }

    // MARK: Alignment / ratio

    private static let ratios: [BackgroundAspectRatio] = BackgroundAspectRatio.presets + [
        .ratio(width: 3, height: 4), .ratio(width: 9, height: 16),
    ]

    private var alignmentAndRatio: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.xl) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text("Alignment").font(.system(size: 12, weight: .medium))
                AlignmentGrid(selected: style?.alignment) { alignment in
                    model.updateBackground { $0.alignment = alignment }
                }
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                Text("Ratio").font(.system(size: 12, weight: .medium))
                Menu(shown.aspectRatio.label) {
                    ForEach(Self.ratios, id: \.self) { ratio in
                        Button(ratio.label) { model.updateBackground { $0.aspectRatio = ratio } }
                    }
                }
                .menuStyle(.button)
                .fixedSize()
            }
        }
        .opacity(style == nil ? 0.5 : 1)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            content()
        }
    }
}

/// Labeled slider; a drag is one undo step.
private struct BackgroundSlider: View {
    let model: EditorViewModel
    let title: String
    let value: Double
    let range: ClosedRange<Double>
    let unit: String
    let set: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value.rounded())) \(unit)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            Slider(
                value: Binding(get: { value }, set: { set($0.rounded()) }),
                in: range
            ) { editing in
                if editing { model.beginBackgroundEdit() } else { model.endBackgroundEdit() }
            }
            .controlSize(.small)
        }
    }
}

/// "+" / wallpaper action tile with a dashed border.
private struct AddSwatch: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: EditorMetrics.backgroundSwatchRadius, style: .continuous)
                .strokeBorder(Color(nsColor: Tokens.Palette.textSecondary).opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .overlay(Image(systemName: symbol).font(.system(size: 13, weight: .medium)))
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                .padding(EditorMetrics.backgroundSelectionRing + 1.5)
                .aspectRatio(1, contentMode: .fit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Round plain-color swatch.
private struct ColorDot: View {
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                .frame(width: EditorMetrics.backgroundColorDot, height: EditorMetrics.backgroundColorDot)
                .padding(3)
                .overlay { if isSelected { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Multicolor wheel opening the system color panel (report §9.3).
private struct CustomColorDot: View {
    let model: EditorViewModel
    let current: RGBAColor?

    var body: some View {
        Button {
            ColorPanelBridge.shared.showBackgroundColor(for: model, initial: current ?? .white)
        } label: {
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                .overlay {
                    if let current {
                        Circle().fill(Color(cgColor: current.cgColor)).padding(7)
                    }
                }
                .frame(width: EditorMetrics.backgroundColorDot, height: EditorMetrics.backgroundColorDot)
                .padding(3)
                .overlay { if current != nil { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Custom color…")
        .accessibilityLabel("Custom color")
    }
}

/// 3×3 position picker; the selected cell is a filled dark square.
struct AlignmentGrid: View {
    let selected: BackgroundAlignment?
    let pick: (BackgroundAlignment) -> Void

    private let rows: [[BackgroundAlignment]] = [
        [.topLeft, .top, .topRight], [.left, .center, .right], [.bottomLeft, .bottom, .bottomRight],
    ]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 3) {
                    ForEach(row, id: \.self) { alignment in
                        Button {
                            pick(alignment)
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(alignment == selected ? Color(nsColor: Tokens.Palette.textPrimary) : Color(nsColor: Tokens.Palette.neutralPillFill))
                                .frame(width: EditorMetrics.backgroundAlignmentCell, height: EditorMetrics.backgroundAlignmentCell)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(alignment.rawValue)
                    }
                }
            }
        }
    }
}
