import AppKit
import HakoKit
import SwiftUI
import UniformTypeIdentifiers

/// Background tab: a compact equivalent of the screenshot editor's
/// `BackgroundPanelView` (which is bound to `EditorViewModel`), bound to
/// `project.canvas.background`. Reuses its swatches (`BackgroundSwatch`,
/// drawn with `BackgroundRenderer`) and `AlignmentGrid`. Adds the Studio
/// aspect-ratio presets (`RecordingAspectRatio.studioPresets`). Padding,
/// corners and shadow are reference points on a 1080 px canvas.
struct BackgroundInspector: View {
    let model: StudioViewModel

    private var style: DocumentBackgroundStyle { model.project.canvas.background }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: EditorMetrics.backgroundSwatchGap), count: 5)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            InspectorSection(title: "Aspect Ratio") { ratios }
            InspectorSection(title: "Gradients") { gradients }
            InspectorSection(title: "Image") { images }
            InspectorSection(title: "Plain Color") { colors }
            Divider()
            sliders
            InspectorSection(title: "Alignment") {
                AlignmentGrid(selected: style.alignment) { alignment in
                    var s = style
                    s.alignment = alignment
                    model.apply(.setBackground(s))
                }
            }
        }
    }

    private var ratios: some View {
        let current = model.project.canvas.aspectRatio
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Tokens.Spacing.xs), count: 3),
                         spacing: Tokens.Spacing.xs) {
            ForEach(RecordingAspectRatio.studioPresets, id: \.self) { ratio in
                Button {
                    model.apply(.setAspectRatio(ratio))
                } label: {
                    Text(ratio.isFreeform ? "Auto" : ratio.description)
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .frame(height: Tokens.Size.pillHeight - 4)
                        .background(
                            RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight, style: .continuous)
                                .fill(ratio == current ? Color.accentColor : Color(nsColor: Tokens.Palette.neutralPillFill))
                        )
                        .foregroundStyle(ratio == current ? Color.white : Color(nsColor: Tokens.Palette.textPrimary))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(ratio.isFreeform ? "Source proportions" : ratio.description)
            }
        }
    }

    private var gradients: some View {
        LazyVGrid(columns: columns, spacing: EditorMetrics.backgroundSwatchGap) {
            ForEach(GradientCatalog.gradients) { preset in
                BackgroundSwatch(fill: .preset(preset.id), isSelected: style.fill == .preset(preset.id), help: preset.name) {
                    model.apply(.setBackgroundFill(.preset(preset.id)))
                }
            }
        }
    }

    private var images: some View {
        LazyVGrid(columns: columns, spacing: EditorMetrics.backgroundSwatchGap) {
            if let (id, image) = model.backgroundImageAsset {
                BackgroundSwatch(fill: .image(id), image: image, isSelected: true, help: "Current image") {}
            }
            BackgroundSwatch(fill: .blurredScreenshot, image: model.thumbnails.first,
                             isSelected: style.fill == .blurredScreenshot, help: "Blurred recording") {
                model.apply(.setBackgroundFill(.blurredScreenshot))
            }
            ImageTile(symbol: "desktopcomputer", help: "Use desktop picture") { useDesktopPicture() }
            ImageTile(symbol: "plus", help: "Choose image…") { chooseImage() }
        }
    }

    private var colors: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
            ForEach(GradientCatalog.solidColors, id: \.self) { color in
                let selected = style.fill == .solid(color)
                Button {
                    model.apply(.setBackgroundFill(.solid(color)))
                } label: {
                    Circle()
                        .fill(Color(cgColor: color.cgColor))
                        .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
                        .frame(width: EditorMetrics.backgroundColorDot, height: EditorMetrics.backgroundColorDot)
                        .padding(3)
                        .overlay { if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2) } }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: customColor, supportsOpacity: false)
                .labelsHidden()
                .help("Custom color…")
        }
    }

    private var customColor: Binding<Color> {
        Binding(
            get: {
                if case .solid(let c) = style.fill { return Color(cgColor: c.cgColor) }
                return .white
            },
            set: { color in
                guard let cg = NSColor(color).usingColorSpace(.sRGB) else { return }
                let rgba = RGBAColor(red: Double(cg.redComponent), green: Double(cg.greenComponent),
                                     blue: Double(cg.blueComponent), alpha: 1)
                model.apply(.setBackgroundFill(.solid(rgba)))
            }
        )
    }

    private var sliders: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            InspectorSlider(model: model, title: "Padding", value: style.padding, range: 0...200, step: 1,
                            format: InspectorFormat.points) { model.apply(.setPadding($0)) }
            InspectorSlider(model: model, title: "Corners", value: style.cornerRadius, range: 0...60, step: 1,
                            format: InspectorFormat.points) { model.apply(.setCornerRadius($0)) }
            InspectorSlider(model: model, title: "Shadow", value: style.shadow.opacity, range: 0...1, step: 0.01,
                            format: InspectorFormat.percent) { v in
                var shadow = style.shadow.radius == 0 ? BackgroundShadow.standard : style.shadow
                shadow.opacity = v
                model.apply(.setShadow(shadow))
            }
        }
    }

    // MARK: Images

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let image = Self.loadImage(url) else { return }
        model.setBackgroundImage(image)
    }

    private func useDesktopPicture() {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        guard let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = Self.loadImage(url) else { return }
        model.setBackgroundImage(image)
    }

    /// Decoded and capped at 3840 px (backgrounds never need more).
    static func loadImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Dashed "+" / desktop tile (same look as the screenshot Background panel).
private struct ImageTile: View {
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
