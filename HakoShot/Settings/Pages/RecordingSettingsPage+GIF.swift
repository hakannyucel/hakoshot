import HakoKit
import SwiftUI

/// Settings › Screen Recording › "GIF" (plan §4.21 "GIF", §4.17;
/// `reports/cleanshot-recording-settings-ui.md` §1.6): Frame rate (15 fps),
/// Resolution (800 × auto), Optimize GIFs (on), Quality slider (~80 %). Used
/// by Record GIF, Quick Access / History "Convert to GIF" and
/// `convert-to-gif` (`GIFConversion.options(settings:)`). Own view type
/// because an extension can't add `@AppStorage` to `RecordingSettingsPage`.
extension RecordingSettingsPage {
    var gifSection: some View {
        GIFSettingsSection()
    }
}

struct GIFSettingsSection: View {
    @AppStorage(.gifFrameRate) private var frameRate: Int
    @AppStorage(.gifWidth) private var width: Int
    @AppStorage(.gifOptimize) private var optimize: Bool
    @AppStorage(.gifQuality) private var quality: Double

    private enum Metrics {
        static let sliderWidth: CGFloat = 180
    }

    var body: some View {
        SettingsCard("GIF") {
            SettingsRow("Frame rate") {
                Picker("Frame rate", selection: $frameRate) {
                    ForEach(Self.frameRateChoices(current: frameRate), id: \.self) { fps in
                        Text("\(fps) fps").tag(fps)
                    }
                }
                .fixedSize()
            }
            SettingsRow("Resolution", description: "Width of the GIF; the height follows the video. Never larger than the video.") {
                Picker("Resolution", selection: $width) {
                    ForEach(Self.widthChoices(current: width), id: \.self) { value in
                        Text(Self.widthTitle(value)).tag(value)
                    }
                }
                .fixedSize()
            }
            SettingsRow("Optimize GIFs", description: "Merges repeated frames and fits the colors to the content for smaller files.") {
                Toggle("Optimize GIFs", isOn: $optimize).toggleStyle(.switch)
            }
            SettingsRow("Quality", description: "Higher quality uses more colors and smoother gradients, and makes bigger files.") {
                HStack(spacing: Tokens.Spacing.s) {
                    Text("Low")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    Slider(value: $quality, in: 0...1)
                        .frame(width: Metrics.sliderWidth)
                        .accessibilityLabel("GIF quality")
                    Text("High")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
            }
        }
    }

    // MARK: Choices (tested)

    /// 5, 10, 15, 20, 24, 30 fps, plus a stored value outside the list (kept, not reset).
    nonisolated static func frameRateChoices(current: Int) -> [Int] {
        let choices = RecordingSettingChoices.gifFrameRates
        return choices.contains(current) || current <= 0 ? choices : (choices + [current]).sorted()
    }

    /// 400…1200 px, then Original (0).
    nonisolated static func widthChoices(current: Int) -> [Int] {
        let choices = RecordingSettingChoices.gifWidths
        guard !choices.contains(current), current > 0 else { return choices }
        let sized = (choices.filter { $0 != RecordingSettingChoices.gifOriginalWidth } + [current]).sorted()
        return sized + [RecordingSettingChoices.gifOriginalWidth]
    }

    /// "800 × auto" / "Original".
    nonisolated static func widthTitle(_ width: Int) -> String {
        width == RecordingSettingChoices.gifOriginalWidth ? "Original" : "\(width) × auto"
    }
}
