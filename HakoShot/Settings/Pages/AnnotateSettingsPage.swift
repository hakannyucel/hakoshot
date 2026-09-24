import AppKit
import HakoKit
import SwiftUI

/// Settings > Annotate (plan §5.3, §5.4): the editor's starting tool options.
struct AnnotateSettingsPage: View {
    @Environment(SettingsWindowModel.self) private var windowModel

    @AppStorage(.annotateDefaultColor) private var colorHex: String
    @AppStorage(.annotateStrokeWidthIndex) private var strokeIndex: Int
    @AppStorage(.annotateTextSizeIndex) private var textSizeIndex: Int
    @AppStorage(.annotateTextStyle) private var textStyle: TextStyle
    @AppStorage(.annotateArrowStyle) private var arrowStyle: ArrowStyle
    @AppStorage(.annotateCounterStyle) private var counterStyle: CounterStyle
    @AppStorage(.annotateRedactionMethod) private var redactionMethod: RedactionMethod
    @AppStorage(.annotateShadow) private var shadow: Bool
    @AppStorage(.annotateRememberLastUsed) private var rememberLastUsed: Bool
    @AppStorage(.annotateLastToolSettings) private var lastToolSettings: String
    @AppStorage(.afterCaptureOpenEditor) private var openEditorAfterCapture: Bool
    @AppStorage(.editorCropSnapToEdges) private var cropSnapping: Bool

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.annotate.title) {
            SettingsCard("Defaults") {
                SettingsRow("Color") {
                    colorSwatches
                }
                SettingsRow("Stroke width") {
                    Picker("Stroke width", selection: resetting($strokeIndex)) {
                        ForEach(StrokeWidthPreset.points.indices, id: \.self) { index in
                            Text("\(Int(StrokeWidthPreset.points[index])) pt").tag(index)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Text size") {
                    Picker("Text size", selection: resetting($textSizeIndex)) {
                        ForEach(TextSizePreset.points.indices, id: \.self) { index in
                            Text("\(Int(TextSizePreset.points[index])) pt").tag(index)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Text style") {
                    Picker("Text style", selection: resetting($textStyle)) {
                        ForEach(TextStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                SettingsRow("Arrow style") {
                    Picker("Arrow style", selection: resetting($arrowStyle)) {
                        ForEach(ArrowStyle.allCases, id: \.self) { style in
                            Label(style.title, systemImage: style.symbol).tag(style)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Counter style") {
                    Picker("Counter style", selection: resetting($counterStyle)) {
                        ForEach(CounterStyle.allCases, id: \.self) { style in
                            Label(style.title, systemImage: style.symbol).tag(style)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Redaction") {
                    Picker("Redaction", selection: resetting($redactionMethod)) {
                        ForEach(RedactionMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                SettingsRow("Shadow", description: "Soft drop shadow under shapes, arrows and text.") {
                    Toggle("Shadow", isOn: resetting($shadow)).toggleStyle(.switch)
                }
            }

            SettingsCard("Editor") {
                SettingsRow(
                    "Remember last used options",
                    description: "New editors start with the color and styles you used last. Changing a default above starts over from the defaults."
                ) {
                    HStack(spacing: Tokens.Spacing.s) {
                        if rememberLastUsed, !lastToolSettings.isEmpty {
                            Button("Reset") { lastToolSettings = "" }
                        }
                        Toggle("Remember last used options", isOn: $rememberLastUsed).toggleStyle(.switch)
                    }
                }
                SettingsRow("Open Annotate tool after capture", description: "Same as General > After capture.") {
                    Toggle("Open Annotate tool after capture", isOn: $openEditorAfterCapture).toggleStyle(.switch)
                }
                SettingsRow("Snap crop to edges", description: "Hold ⌘ while cropping to do the opposite.") {
                    Toggle("Snap crop to edges", isOn: $cropSnapping).toggleStyle(.switch)
                }
            }

            SettingsCard("Background tool") {
                SettingsRow("Default background and presets", description: "Gradient, padding, corners and shadow the Background tool starts with.") {
                    Button("Open Wallpaper") { windowModel.selection = .wallpaper }
                }
            }
        }
    }

    // MARK: Color

    private var colorSwatches: some View {
        HStack(spacing: Tokens.Spacing.xs + Tokens.Spacing.xxs) {
            ForEach(RGBAColor.annotationPalette, id: \.self) { swatch in
                let selected = hex(swatch) == colorHex.uppercased()
                Button {
                    setColor(swatch)
                } label: {
                    Circle()
                        .fill(Color(rgba: swatch))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: Tokens.Stroke.hairline))
                        .padding(Tokens.Stroke.settingsThumbRing + 1)
                        .overlay {
                            if selected {
                                Circle().strokeBorder(Color.accentColor, lineWidth: Tokens.Stroke.settingsThumbRing)
                            }
                        }
                        .frame(width: SettingsMetrics.colorSwatch, height: SettingsMetrics.colorSwatch)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(hex(swatch))
                .accessibilityLabel(hex(swatch))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: false)
                .help("Custom color")
        }
    }

    private func hex(_ color: RGBAColor) -> String {
        String(color.hexString.prefix(7)).uppercased()
    }

    private func setColor(_ color: RGBAColor) {
        colorHex = hex(color)
        lastToolSettings = ""
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: RGBAColor(hex: colorHex) ?? .defaultAnnotation) },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                setColor(RGBAColor(
                    red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)
                ))
            }
        )
    }

    /// A default changed: forget the remembered options so it applies to the next editor.
    private func resetting<Value>(_ binding: Binding<Value>) -> Binding<Value> {
        Binding(
            get: { binding.wrappedValue },
            set: { newValue in
                binding.wrappedValue = newValue
                lastToolSettings = ""
            }
        )
    }
}

