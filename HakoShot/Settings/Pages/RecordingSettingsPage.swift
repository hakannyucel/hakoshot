import AppKit
import HakoKit
import SwiftUI

/// Settings > Screen Recording (plan §4.21, §5; row order, labels and defaults
/// verified against CleanShot's official screenshots in
/// `reports/cleanshot-recording-settings-ui.md` §1.1–§1.6).
///
/// Section order matches the official page: General, Cursor, Keystrokes,
/// Video, Audio, Camera (HakoShot addition — no CleanShot equivalent was
/// found on this page, see report §1.7), GIF. This package (R1.5) builds
/// General, Cursor and Video; Keystrokes, Audio, Camera and GIF are
/// `EmptyView` placeholders defined in `RecordingSettingsPage+Keystrokes.swift`,
/// `+Audio.swift`, `+Camera.swift` and `+GIF.swift` — later packages fill
/// those files in without editing this one (`body` only lists the section
/// properties, it doesn't build their content).
///
/// Not wired into `SettingsSidebar.swift` (hotspot, plan §7.0): see the
/// integration snippet in this package's report.
struct RecordingSettingsPage: View {
    // MARK: General

    @AppStorage(.recordingShowControls) private var showControls: Bool
    @AppStorage(.recordingRememberLastSelection) private var rememberLastSelection: Bool
    @AppStorage(.recordingShowTimeInMenuBar) private var showTimeInMenuBar: Bool
    @AppStorage(.recordingDimScreen) private var dimScreen: Bool
    @AppStorage(.recordingShowCountdown) private var showCountdown: Bool
    @AppStorage(.recordingCountdownSeconds) private var countdownSeconds: Int
    @AppStorage(.recordingDoNotDisturb) private var doNotDisturb: Bool
    @AppStorage(.recordingHideDesktopIcons) private var hideDesktopIcons: Bool

    // MARK: Cursor

    @AppStorage(.recordingShowCursor) private var showCursor: Bool
    @AppStorage(.recordingHighlightClicks) private var highlightClicks: Bool

    // MARK: Video

    @AppStorage(.recordingFrameRate) private var frameRate: Int
    @AppStorage(.recordingMaxResolution) private var maxResolution: RecordingMaxResolution
    @AppStorage(.recordingQuality) private var quality: RecordingQuality
    @AppStorage(.recordingCodec) private var codec: RecordingCodec
    @AppStorage(.recordingScaleRetinaTo1x) private var scaleRetinaTo1x: Bool

    @State private var showsDoNotDisturbSetup = false
    @State private var showsClickOptions = false

    var body: some View {
        SettingsPageScaffold(title: "Screen Recording") {
            generalSection
            cursorSection
            keystrokesSection
            videoSection
            audioSection
            cameraSection
            gifSection
        }
        .sheet(isPresented: $showsDoNotDisturbSetup) {
            DoNotDisturbSetupSheet()
        }
    }

    // MARK: - General

    private var generalSection: some View {
        SettingsCard("General") {
            SettingsRow("Show controls while recording", description: "A pause/stop bar at the bottom of the screen.") {
                Toggle("Show controls while recording", isOn: $showControls).toggleStyle(.switch)
            }
            SettingsRow("Remember last selection", description: "The area picker opens with the area you used last time.") {
                Toggle("Remember last selection", isOn: $rememberLastSelection).toggleStyle(.switch)
            }
            SettingsRow("Display recording time in menu bar") {
                Toggle("Display recording time in menu bar", isOn: $showTimeInMenuBar).toggleStyle(.switch)
            }
            SettingsRow("Dim screen while recording", description: "Everything outside the recorded area darkens.") {
                Toggle("Dim screen while recording", isOn: $dimScreen).toggleStyle(.switch)
            }
            SettingsRow("Show countdown", description: "A few seconds to get ready before recording starts. Esc cancels.") {
                HStack(spacing: Tokens.Spacing.s) {
                    Picker("Countdown seconds", selection: $countdownSeconds) {
                        ForEach(RecordingSettingChoices.countdownSeconds, id: \.self) { seconds in
                            Text("\(seconds) seconds").tag(seconds)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!Self.countdownPickerEnabled(showCountdown: showCountdown))
                    Toggle("Show countdown", isOn: $showCountdown).toggleStyle(.switch)
                }
            }
            SettingsRow("“Do Not Disturb” while recording", description: "Keeps notification banners out of the video.") {
                HStack(spacing: Tokens.Spacing.s) {
                    Button("Set up…") { showsDoNotDisturbSetup = true }
                    Toggle("Do Not Disturb while recording", isOn: $doNotDisturb).toggleStyle(.switch)
                }
            }
            SettingsRow("Hide desktop icons while recording") {
                Toggle("Hide desktop icons while recording", isOn: $hideDesktopIcons).toggleStyle(.switch)
            }
        }
    }

    /// The countdown-seconds picker is only meaningful while "Show countdown"
    /// is on; kept as a static, testable function rather than an inline
    /// `!showCountdown` since R1.5's tests check this rule directly.
    static func countdownPickerEnabled(showCountdown: Bool) -> Bool {
        showCountdown
    }

    // MARK: - Cursor

    private var cursorSection: some View {
        SettingsCard("Cursor") {
            SettingsRow("Show cursor") {
                Toggle("Show cursor", isOn: $showCursor).toggleStyle(.switch)
            }
            SettingsRow("Highlight clicks") {
                HStack(spacing: Tokens.Spacing.s) {
                    Button("Options…") { showsClickOptions = true }
                        .disabled(!highlightClicks)
                        .popover(isPresented: $showsClickOptions, arrowEdge: .top) {
                            ClickHighlightOptionsPopover()
                        }
                    Toggle("Highlight clicks", isOn: $highlightClicks).toggleStyle(.switch)
                }
            }
        }
    }

    // MARK: - Video

    private var videoSection: some View {
        SettingsCard("Video") {
            SettingsRow("Frame rate") {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach(RecordingSettingChoices.frameRates, id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .fixedSize()
            }
            SettingsRow("Max resolution", description: "Caps the output's short edge to reduce file size and upload time.") {
                Picker("Max resolution", selection: $maxResolution) {
                    ForEach(RecordingMaxResolution.allCases, id: \.self) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                .fixedSize()
            }
            SettingsRow("Quality") {
                Picker("Quality", selection: $quality) {
                    ForEach(RecordingQuality.allCases, id: \.self) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .fixedSize()
            }
            SettingsRow("Codec", description: "5K displays use HEVC automatically, regardless of this setting.") {
                Picker("Codec", selection: $codec) {
                    ForEach(RecordingCodec.allCases, id: \.self) { codec in
                        Text(codec.title).tag(codec)
                    }
                }
                .fixedSize()
            }
            SettingsRow("Scale Retina videos to 1x", description: "Halves the pixel dimensions of Retina recordings.") {
                Toggle("Scale Retina videos to 1x", isOn: $scaleRetinaTo1x).toggleStyle(.switch)
            }
        }
    }
}

/// Highlight Clicks "Options…" popover (plan §4.21 "Cursor", §4.9; CleanShot
/// `/features` text: color, size, style, animation — popover itself not
/// visually verified, see report §1.2).
private struct ClickHighlightOptionsPopover: View {
    @AppStorage(.recordingClickColor) private var colorHex: String
    @AppStorage(.recordingClickSize) private var size: RecordingElementSize
    @AppStorage(.recordingClickStyle) private var style: ClickHighlightStyle
    @AppStorage(.recordingClickAnimated) private var animated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text("Highlight Clicks")
                .font(Tokens.Typography.sectionHeader)

            HStack {
                Text("Color")
                Spacer(minLength: Tokens.Spacing.m)
                ColorPicker("Color", selection: colorBinding, supportsOpacity: false)
                    .labelsHidden()
            }
            HStack {
                Text("Size")
                Spacer(minLength: Tokens.Spacing.m)
                Picker("Size", selection: $size) {
                    ForEach(RecordingElementSize.allCases, id: \.self) { size in
                        Text(size.title).tag(size)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("Style")
                Spacer(minLength: Tokens.Spacing.m)
                Picker("Style", selection: $style) {
                    Text("Outline").tag(ClickHighlightStyle.outline)
                    Text("Filled").tag(ClickHighlightStyle.filled)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Toggle("Animated", isOn: $animated)
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 260)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(rgba: RGBAColor(hex: colorHex) ?? .annotationBlue) },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                let color = RGBAColor(
                    red: Double(srgb.redComponent), green: Double(srgb.greenComponent), blue: Double(srgb.blueComponent)
                )
                colorHex = String(color.hexString.prefix(7))
            }
        )
    }
}
