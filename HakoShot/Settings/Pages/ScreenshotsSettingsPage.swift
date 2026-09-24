import AppKit
import HakoKit
import SwiftUI

/// Settings > Screenshots (plan §5.3).
struct ScreenshotsSettingsPage: View {
    @AppStorage(.outputImageFormat) private var format: ImageFormat
    @AppStorage(.outputJPEGQuality) private var jpegQuality: Double
    @AppStorage(.outputHEICQuality) private var heicQuality: Double
    @AppStorage(.outputWebPQuality) private var webpQuality: Double

    @AppStorage(.captureCursor) private var captureCursor: Bool

    @AppStorage(.windowCaptureShadow) private var windowShadow: Bool
    @AppStorage(.windowCaptureBackground) private var windowBackground: WindowCaptureBackgroundKind
    @AppStorage(.windowCaptureBackgroundColor) private var windowBackgroundColor: String
    @AppStorage(.windowCapturePadding) private var windowPadding: Double

    @AppStorage(.screenshotFullscreenDisplay) private var fullscreenDisplay: FullscreenDisplayPreference
    @AppStorage(.cropNotch) private var cropNotch: Bool

    @AppStorage(.showCrosshair) private var crosshairMode: CrosshairMode
    @AppStorage(.showMagnifier) private var showMagnifier: Bool
    @AppStorage(.freezeScreen) private var freezeScreen: Bool

    @AppStorage(.selfTimerSeconds) private var selfTimerSeconds: Int
    @AppStorage(.allInOneRemembersSelection) private var allInOneRemembersSelection: Bool

    @AppStorage(.scrollingStartAutomatically) private var scrollingStartAutomatically: Bool
    @AppStorage(.scrollingFinishAtContentEnd) private var scrollingFinishAtContentEnd: Bool
    @AppStorage(.scrollingAutoScrollSpeed) private var scrollingSpeed: ScrollingAutoScrollSpeed
    @AppStorage(.scrollingMaximumLength) private var scrollingMaximumLength: Int

    var body: some View {
        SettingsPageScaffold(title: SettingsPage.screenshots.title) {
            SettingsCard("File") {
                SettingsRow("File format") {
                    Picker("File format", selection: $format) {
                        ForEach(ImageFormat.allCases.filter(\.isEncodable), id: \.self) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .fixedSize()
                }
                if let quality = qualityBinding {
                    SettingsRow("Quality", description: "\(Int((quality.wrappedValue * 100).rounded()))%") {
                        Slider(value: quality, in: 0.1...1, step: 0.05)
                            .frame(width: 180)
                    }
                }
            }

            SettingsCard("Selection") {
                SettingsRow("Crosshair", description: "Guide lines through the cursor before you drag.") {
                    Picker("Crosshair", selection: $crosshairMode) {
                        Text("Always").tag(CrosshairMode.always)
                        Text("While holding ⌘").tag(CrosshairMode.holdCommand)
                        Text("Off").tag(CrosshairMode.off)
                    }
                    .fixedSize()
                }
                SettingsRow("Show magnifier", description: "Zoomed pixels next to the cursor. Press M to toggle while selecting.") {
                    Toggle("Show magnifier", isOn: $showMagnifier)
                        .toggleStyle(.switch)
                }
                SettingsRow(
                    "Freeze screen",
                    description: "Select on a still image taken when you press the shortcut, so menus and hover states can be captured."
                ) {
                    Toggle("Freeze screen", isOn: $freezeScreen)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard("Capture") {
                SettingsRow("Show cursor", description: "Draw the mouse pointer into area and fullscreen captures.") {
                    Toggle("Show cursor", isOn: $captureCursor)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard("Self-timer & All-In-One") {
                SettingsRow("Self-timer interval", description: "Countdown before a self-timer capture. Esc cancels.") {
                    Picker("Self-timer interval", selection: $selfTimerSeconds) {
                        ForEach(SelfTimerSettings.intervalChoices, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow(
                    "Remember last selection",
                    description: "All-In-One opens with the area you used last time, for quick retakes."
                ) {
                    Toggle("Remember last selection", isOn: $allInOneRemembersSelection)
                        .toggleStyle(.switch)
                }
            }

            SettingsCard("Scrolling capture") {
                SettingsRow(
                    "Start capturing automatically",
                    description: "Begin as soon as the area is selected. Off: press Start Capture first."
                ) {
                    Toggle("Start capturing automatically", isOn: $scrollingStartAutomatically)
                        .toggleStyle(.switch)
                }
                SettingsRow(
                    "Finish at end of content",
                    description: "When auto-scroll reaches the bottom, finish the capture instead of only stopping."
                ) {
                    Toggle("Finish at end of content", isOn: $scrollingFinishAtContentEnd)
                        .toggleStyle(.switch)
                }
                SettingsRow("Auto-scroll speed") {
                    Picker("Auto-scroll speed", selection: $scrollingSpeed) {
                        ForEach(ScrollingAutoScrollSpeed.allCases, id: \.self) { speed in
                            Text(speed.title).tag(speed)
                        }
                    }
                    .fixedSize()
                }
                SettingsRow("Maximum length", description: "The capture stops by itself at this height (or width).") {
                    Picker("Maximum length", selection: $scrollingMaximumLength) {
                        ForEach(Self.scrollingLengthChoices(including: scrollingMaximumLength), id: \.self) { length in
                            Text("\(length.formatted()) px").tag(length)
                        }
                    }
                    .fixedSize()
                }
            }

            SettingsCard("Window screenshots") {
                SettingsRow("Capture window shadow") {
                    Toggle("Capture window shadow", isOn: $windowShadow)
                        .toggleStyle(.switch)
                }
                SettingsRow("Background") {
                    Picker("Background", selection: $windowBackground) {
                        Text("Transparent").tag(WindowCaptureBackgroundKind.transparent)
                        Text("Wallpaper").tag(WindowCaptureBackgroundKind.wallpaper)
                        Text("Solid color").tag(WindowCaptureBackgroundKind.solidColor)
                    }
                    .fixedSize()
                }
                if windowBackground == .solidColor {
                    SettingsRow("Background color") {
                        ColorPicker("Background color", selection: backgroundColorBinding, supportsOpacity: false)
                    }
                }
                SettingsRow("Padding", description: "\(Int(windowPadding)) pt around the window") {
                    Slider(value: $windowPadding, in: 0...200, step: 4)
                        .frame(width: 180)
                }
                .disabled(windowBackground == .transparent)
            }

            SettingsCard("Fullscreen") {
                SettingsRow("Display") {
                    Picker("Display", selection: $fullscreenDisplay) {
                        Text("Active display").tag(FullscreenDisplayPreference.active)
                        Text("All displays").tag(FullscreenDisplayPreference.all)
                    }
                    .fixedSize()
                }
                SettingsRow(
                    "Crop notch area",
                    description: "Remove the menu bar strip beside the camera notch in fullscreen captures."
                ) {
                    Toggle("Crop notch area", isOn: $cropNotch)
                        .toggleStyle(.switch)
                }
            }
        }
    }

    /// Maximum-length menu; keeps a custom stored value selectable.
    private static func scrollingLengthChoices(including current: Int) -> [Int] {
        Array(Set([10_000, 20_000, 32_000, current])).sorted()
    }

    /// The quality setting for the selected lossy format; `nil` for PNG.
    private var qualityBinding: Binding<Double>? {
        switch format {
        case .png: nil
        case .jpeg: $jpegQuality
        case .heic: $heicQuality
        case .webp: $webpQuality
        }
    }

    private var backgroundColorBinding: Binding<Color> {
        Binding(
            get: {
                let color = RGBAColor(hex: windowBackgroundColor) ?? .white
                return Color(.sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
            },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                let color = RGBAColor(
                    red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)
                )
                windowBackgroundColor = String(color.hexString.prefix(7))
            }
        )
    }
}

private extension ImageFormat {
    var displayName: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .heic: "HEIC"
        case .webp: "WebP"
        }
    }
}
