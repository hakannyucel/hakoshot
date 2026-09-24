import AppKit
import HakoKit
import SwiftUI

/// Settings > Wallpaper (plan §5.3): the Background tool's starting style and
/// saved presets. Writes `editorBackgroundLastStyle` / `editorBackgroundPresets`,
/// which the editor's Background panel reads.
struct WallpaperSettingsPage: View {
    @Environment(SettingsWindowModel.self) private var windowModel
    @AppStorage(.editorBackgroundLastStyle) private var styleJSON: String
    @AppStorage(.editorBackgroundPresets) private var presetsJSON: String

    /// Preview shrinks points so a 64 pt padding fits the card.
    private static let previewScale = 0.35

    private var style: DocumentBackgroundStyle { WallpaperDefaults.style(from: styleJSON) }
    private var presets: [BackgroundPreset] { BackgroundPresetStore.decode(presetsJSON) }

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.wallpaper.title) {
            SettingsCard("Default background") {
                VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                    preview
                    Text("The Background tool (B in the editor) starts with this. Changes you make in the editor show up here too.")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    swatchGrid(WallpaperDefaults.gradientFills)
                    swatchGrid(WallpaperDefaults.solidFills + [.transparent])
                }
                .padding(.vertical, Tokens.Spacing.settingsRowV)
                .padding(.horizontal, Tokens.Spacing.settingsRowH)
            }

            SettingsCard("Layout") {
                slider("Padding", value: \.padding, range: 0...200, step: 4, unit: "pt")
                slider("Inset", value: \.inset, range: 0...100, step: 2, unit: "pt")
                slider("Corner radius", value: \.cornerRadius, range: 0...60, step: 1, unit: "pt")
                SettingsRow("Shadow", description: "\(Int((style.shadow.opacity * 100).rounded()))%") {
                    Slider(value: binding(\.shadow.opacity), in: 0...1, step: 0.05)
                        .frame(width: 180)
                }
                SettingsRow("Auto-balance", description: "Evens out a screenshot's own plain margins.") {
                    Toggle("Auto-balance", isOn: binding(\.autoBalance)).toggleStyle(.switch)
                }
                SettingsRow("Restore defaults", description: "Aurora gradient, 64 pt padding, 12 pt corners, 50% shadow.") {
                    Button("Restore") { styleJSON = "" }
                        .disabled(style == .standard)
                }
            }

            SettingsCard("Presets") {
                if presets.isEmpty {
                    SettingsRow("No presets yet", description: "Save one from the Background tool's Presets menu in the editor.")
                } else {
                    ForEach(presets) { preset in
                        presetRow(preset)
                    }
                }
            }

            SettingsCard("Window screenshots") {
                SettingsRow(
                    "Window background",
                    description: "Transparent, desktop wallpaper or a solid color behind window captures."
                ) {
                    Button("Open Screenshots") { windowModel.selection = .screenshots }
                }
            }
        }
    }

    // MARK: Preview

    private var preview: some View {
        let current = style
        let scale = Self.previewScale
        return RoundedRectangle(cornerRadius: current.cornerRadius * scale, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { dot in
                        Circle().fill(dot.opacity(0.8)).frame(width: 6, height: 6)
                    }
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: current.cornerRadius * scale, style: .continuous))
            .shadow(
                color: .black.opacity(current.shadow.opacity),
                radius: current.shadow.radius * scale,
                x: current.shadow.offsetX * scale,
                y: current.shadow.offsetY * scale
            )
            .padding(current.padding * scale)
            .frame(maxWidth: .infinity)
            .frame(height: SettingsMetrics.wallpaperPreviewHeight)
            .background { WallpaperFillImage(fill: current.fill) }
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.wallpaperSwatchRadius, style: .continuous))
            .accessibilityLabel("Preview: \(WallpaperDefaults.title(for: current.fill))")
    }

    // MARK: Swatches

    private func swatchGrid(_ fills: [BackgroundFill]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: SettingsMetrics.wallpaperSwatch), spacing: Tokens.Spacing.s)],
            alignment: .leading,
            spacing: Tokens.Spacing.s
        ) {
            ForEach(fills, id: \.self) { fill in
                swatch(fill)
            }
        }
    }

    private func swatch(_ fill: BackgroundFill) -> some View {
        let selected = style.fill == fill
        return Button {
            update { $0.fill = fill }
        } label: {
            WallpaperFillImage(fill: fill)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.wallpaperSwatchRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: SettingsMetrics.wallpaperSwatchRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: Tokens.Stroke.hairline)
                }
                .padding(Tokens.Stroke.selectionRing)
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: SettingsMetrics.wallpaperSwatchRadius + Tokens.Stroke.selectionRing, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: Tokens.Stroke.settingsThumbRing)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(WallpaperDefaults.title(for: fill))
        .accessibilityLabel(WallpaperDefaults.title(for: fill))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    // MARK: Presets

    private func presetRow(_ preset: BackgroundPreset) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            WallpaperFillImage(fill: preset.style.fill)
                .frame(width: 36, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.swatchSmall / 2, style: .continuous))
            VStack(alignment: .leading, spacing: Tokens.Spacing.settingsRowTextGap) {
                Text(preset.name).font(Tokens.Typography.rowLabel)
                Text("\(WallpaperDefaults.title(for: preset.style.fill)), \(Int(preset.style.padding)) pt padding")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            Spacer(minLength: 0)
            Button("Use as Default") { styleJSON = WallpaperDefaults.json(for: preset.style) }
                .disabled(BackgroundPresetStore.portable(preset.style) == style)
            Button {
                presetsJSON = BackgroundPresetStore.encode(presets.filter { $0.id != preset.id })
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete preset")
            .accessibilityLabel("Delete \(preset.name)")
        }
        .padding(.vertical, Tokens.Spacing.s)
        .padding(.horizontal, Tokens.Spacing.settingsRowH)
    }

    // MARK: Editing

    private func update(_ body: (inout DocumentBackgroundStyle) -> Void) {
        var copy = style
        body(&copy)
        styleJSON = WallpaperDefaults.json(for: copy)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<DocumentBackgroundStyle, Value>) -> Binding<Value> {
        Binding(get: { style[keyPath: keyPath] }, set: { newValue in update { $0[keyPath: keyPath] = newValue } })
    }

    private func slider(
        _ title: String, value keyPath: WritableKeyPath<DocumentBackgroundStyle, Double>,
        range: ClosedRange<Double>, step: Double, unit: String
    ) -> some View {
        SettingsRow(title, description: "\(Int(style[keyPath: keyPath])) \(unit)") {
            Slider(value: binding(keyPath), in: range, step: step)
                .frame(width: 180)
        }
    }
}

/// A background fill drawn with the export renderer, stretched to the view.
private struct WallpaperFillImage: View {
    let fill: BackgroundFill

    var body: some View {
        if fill == .transparent {
            Checkerboard()
        } else if let image = BackgroundSwatchRenderer.image(for: fill, pixels: 160) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            Color.gray
        }
    }
}

/// Transparent swatch.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int(size.height / cell) + 1 {
                for column in 0..<Int(size.width / cell) + 1 where (row + column).isMultiple(of: 2) {
                    let rect = CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}
