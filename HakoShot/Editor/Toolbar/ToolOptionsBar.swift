import AppKit
import HakoKit
import SwiftUI

/// Options for the current tool or selection (report §9.1 item 5): color dot,
/// size "6 pt ⌄", and per-tool style controls.
struct ToolOptionsBar: View {
    let model: EditorViewModel
    let options: EditorOptions
    /// Icons only (used when the toolbar is narrow).
    var compact = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if showsColor {
                ColorOptionButton(model: model, color: options.color)
            }
            if showsSize {
                SizeMenu(model: model, options: options)
            }
            toolSpecific
            if showsShadow {
                OptionToggleButton(symbol: "square.3.layers.3d.down.right", help: "Shadow", isOn: options.shadow) {
                    model.setShadow(!options.shadow)
                }
            }
        }
        .fixedSize()
    }

    @ViewBuilder
    private var toolSpecific: some View {
        switch options.tool {
        case .arrow:
            OptionMenu(title: compact ? nil : options.arrowStyle.title, symbol: options.arrowStyle.symbol, help: "Arrow style") {
                ForEach(ArrowStyle.allCases, id: \.self) { style in
                    Button {
                        model.setArrowStyle(style)
                    } label: {
                        Label(style.title, systemImage: style.symbol)
                    }
                }
            }
        case .text:
            OptionMenu(title: compact ? nil : options.textStyle.title, symbol: "textformat", help: "Text style") {
                ForEach(TextStyle.allCases, id: \.self) { style in
                    Button(style.title) { model.setTextStyle(style) }
                }
            }
            HStack(spacing: 0) {
                ForEach(TextAlignmentMode.allCases, id: \.self) { alignment in
                    OptionToggleButton(symbol: alignment.symbol, help: "Align \(alignment.rawValue)", isOn: options.textAlignment == alignment) {
                        model.setTextAlignment(alignment)
                    }
                }
            }
        case .counter:
            OptionMenu(title: compact ? nil : options.counterStyle.title, symbol: options.counterStyle.symbol, help: "Counter style") {
                ForEach(CounterStyle.allCases, id: \.self) { style in
                    Button {
                        model.setCounterStyle(style)
                    } label: {
                        Label(style.title, systemImage: style.symbol)
                    }
                }
            }
            CounterStartControl(model: model, start: options.counterStart, compact: compact)
        case .redaction:
            OptionMenu(title: options.redactionMethod.shortTitle, symbol: compact ? nil : "checkerboard.rectangle", help: "Redaction method") {
                ForEach(RedactionMethod.allCases, id: \.self) { method in
                    Button(method.title) { model.setRedactionMethod(method) }
                }
            }
        case .rectangle, .ellipse:
            OptionToggleButton(symbol: options.tool == .ellipse ? "circle.fill" : "square.fill", help: "Fill", isOn: options.fill) {
                model.setFill(!options.fill)
            }
        default:
            EmptyView()
        }
    }

    private var showsColor: Bool {
        options.tool != .redaction && options.tool != .spotlight
    }

    private var showsSize: Bool {
        switch options.tool {
        case .filledRectangle, .redaction, .spotlight: false
        default: true
        }
    }

    private var showsShadow: Bool {
        switch options.tool {
        case .highlighter, .redaction, .spotlight: false
        default: true
        }
    }
}

/// "6 pt ⌄" / "30 pt ⌄" menu; items list the `1`–`6` keys.
struct SizeMenu: View {
    let model: EditorViewModel
    let options: EditorOptions

    var body: some View {
        let presets = options.usesTextSizes ? TextSizePreset.points : StrokeWidthPreset.points
        OptionMenu(title: "\(Self.format(options.sizePoints)) pt", symbol: nil, help: options.usesTextSizes ? "Text size (1–6)" : "Stroke width (1–6)") {
            ForEach(presets.indices, id: \.self) { index in
                Button {
                    model.setSizePreset(index)
                } label: {
                    Text("\(Self.format(presets[index])) pt   (\(index + 1))")
                }
            }
        }
    }

    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
    }
}

/// Compact menu button: optional icon + title + chevron.
struct OptionMenu<Content: View>: View {
    let title: String?
    let symbol: String?
    let help: String
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        Menu {
            content()
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .medium))
                }
                if let title {
                    Text(title)
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
            .padding(.horizontal, Tokens.Spacing.s - 2)
            .frame(height: EditorMetrics.optionControlHeight)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight - 2, style: .continuous)
                    .fill(hovering ? Color(nsColor: Tokens.Palette.selectionFill) : .clear)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(help)
        .onHover { hovering = $0 }
    }
}

/// Icon toggle (fill, shadow, alignment).
struct OptionToggleButton: View {
    let symbol: String
    let help: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: EditorMetrics.optionControlHeight, height: EditorMetrics.optionControlHeight)
                .foregroundStyle(isOn ? Color.accentColor : Color(nsColor: Tokens.Palette.textSecondary))
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight - 2, style: .continuous)
                        .fill(isOn ? Color.accentColor.opacity(0.14) : (hovering ? Color(nsColor: Tokens.Palette.selectionFill) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .onHover { hovering = $0 }
    }
}

/// Counter start number (0 allowed, plan §4.10). Renumbers existing counters.
struct CounterStartControl: View {
    let model: EditorViewModel
    let start: Int
    var compact = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Text(compact ? "\(start)" : "Start \(start)")
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
            Stepper("Start number", value: Binding(get: { start }, set: { model.setCounterStart($0) }), in: 0...999)
                .labelsHidden()
                .controlSize(.small)
        }
        .help("Counter start number")
    }
}

/// Color dot + chevron; popover with the palette (plan §5.4) + custom colors.
struct ColorOptionButton: View {
    let model: EditorViewModel
    let color: RGBAColor
    @State private var showsPalette = false
    @State private var hovering = false

    var body: some View {
        Button {
            showsPalette.toggle()
        } label: {
            HStack(spacing: 3) {
                Circle()
                    .fill(Color(rgba: color))
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: Tokens.Stroke.hairline))
                    .frame(width: EditorMetrics.optionColorDot, height: EditorMetrics.optionColorDot)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            .padding(.horizontal, Tokens.Spacing.xs)
            .frame(height: EditorMetrics.optionControlHeight)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight - 2, style: .continuous)
                    .fill(hovering ? Color(nsColor: Tokens.Palette.selectionFill) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Color")
        .onHover { hovering = $0 }
        .popover(isPresented: $showsPalette, arrowEdge: .bottom) {
            ColorPalettePopover(model: model, selected: color) { showsPalette = false }
        }
    }
}

struct ColorPalettePopover: View {
    let model: EditorViewModel
    let selected: RGBAColor
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(EditorMetrics.paletteSwatch), spacing: Tokens.Spacing.s), count: EditorMetrics.paletteColumns),
                spacing: Tokens.Spacing.s
            ) {
                ForEach(RGBAColor.annotationPalette, id: \.self) { swatch in
                    Button {
                        model.setColor(swatch)
                        dismiss()
                    } label: {
                        Circle()
                            .fill(Color(rgba: swatch))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: Tokens.Stroke.hairline))
                            .padding(3)
                            .overlay {
                                if swatch.hexString == selected.hexString {
                                    Circle().strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .frame(width: EditorMetrics.paletteSwatch, height: EditorMetrics.paletteSwatch)
                    }
                    .buttonStyle(.plain)
                    .help(swatch.hexString)
                }
            }
            Divider()
            HStack(spacing: Tokens.Spacing.s) {
                Button("Custom…") {
                    ColorPanelBridge.shared.show(for: model, initial: selected)
                    dismiss()
                }
                Button {
                    dismiss()
                    NSColorSampler().show { [weak model] picked in
                        // The sampler calls back on the main thread.
                        MainActor.assumeIsolated {
                            guard let picked, let model else { return }
                            model.setColor(RGBAColor(nsColor: picked))
                        }
                    }
                } label: {
                    Label("Pick", systemImage: "eyedropper")
                }
                .help("Pick a color from the screen")
            }
            .controlSize(.small)
        }
        .padding(Tokens.Spacing.m)
    }
}

/// Routes `NSColorPanel` changes to the editor that opened it.
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private weak var model: EditorViewModel?
    private var handler: ((EditorViewModel, RGBAColor) -> Void)?

    /// Annotation color (option bar).
    func show(for model: EditorViewModel, initial: RGBAColor) {
        show(for: model, initial: initial, showsAlpha: true) { $0.setColorCoalesced($1) }
    }

    /// Background panel custom plain color (opaque).
    func showBackgroundColor(for model: EditorViewModel, initial: RGBAColor) {
        show(for: model, initial: initial, showsAlpha: false) { $0.setBackgroundFillCoalesced(.solid($1.withAlpha(1))) }
    }

    private func show(for model: EditorViewModel, initial: RGBAColor, showsAlpha: Bool,
                      handler: @escaping (EditorViewModel, RGBAColor) -> Void) {
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.showsAlpha = showsAlpha
        panel.isContinuous = true
        panel.color = NSColor(rgba: initial)
        self.model = model
        self.handler = handler
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.orderFront(nil)
    }

    /// An editor closing detaches the panel from it.
    func detach(_ model: EditorViewModel) {
        guard self.model === model else { return }
        self.model = nil
        handler = nil
        NSColorPanel.shared.setTarget(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let model else { return }
        handler?(model, RGBAColor(nsColor: sender.color))
    }
}

// MARK: - Color bridging

extension RGBAColor {
    init(nsColor: NSColor) {
        let c = nsColor.usingColorSpace(.sRGB) ?? NSColor.black
        self.init(red: Double(c.redComponent), green: Double(c.greenComponent), blue: Double(c.blueComponent), alpha: Double(c.alphaComponent))
    }
}

extension NSColor {
    convenience init(rgba: RGBAColor) {
        self.init(srgbRed: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }
}

extension Color {
    init(rgba: RGBAColor) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}
