import Foundation
import HakoKit
import Testing
@testable import HakoShot

// R1.5 "Recording ayar sayfası (1)": defaults for every SettingsKey the
// General/Cursor/Video sections of RecordingSettingsPage bind to, matching
// the contract in `HakoShot/Recording/Contracts/RecordingSettings.swift`
// (plan §4.21, §5), plus the countdown-picker enablement rule.

@MainActor
private func scratchSettings(_ name: String = #function) -> AppSettings {
    let suite = "com.hakanyucel.hakoshot.tests.recordingsettingspage.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    return AppSettings(defaults: defaults)
}

@Suite("RecordingSettingsPage defaults") @MainActor
struct RecordingSettingsPageDefaultsTests {
    @Test func generalDefaultsMatchContract() {
        let settings = scratchSettings()
        #expect(settings.value(for: .recordingShowControls) == true)
        #expect(settings.value(for: .recordingRememberLastSelection) == true)
        #expect(settings.value(for: .recordingShowTimeInMenuBar) == false)
        #expect(settings.value(for: .recordingDimScreen) == true)
        #expect(settings.value(for: .recordingShowCountdown) == false)
        #expect(settings.value(for: .recordingCountdownSeconds) == 3)
        #expect(settings.value(for: .recordingDoNotDisturb) == false)
        #expect(settings.value(for: .recordingHideDesktopIcons) == false)
    }

    @Test func cursorDefaultsMatchContract() {
        let settings = scratchSettings()
        #expect(settings.value(for: .recordingShowCursor) == true)
        #expect(settings.value(for: .recordingHighlightClicks) == true)
        #expect(settings.value(for: .recordingClickColor) == "#0A84FF")
        #expect(settings.value(for: .recordingClickSize) == .medium)
        #expect(settings.value(for: .recordingClickStyle) == .outline)
        #expect(settings.value(for: .recordingClickAnimated) == true)
    }

    @Test func videoDefaultsMatchContract() {
        let settings = scratchSettings()
        #expect(settings.value(for: .recordingFrameRate) == 60)
        #expect(settings.value(for: .recordingMaxResolution) == .original)
        #expect(settings.value(for: .recordingQuality) == .high)
        #expect(settings.value(for: .recordingCodec) == .h264)
        #expect(settings.value(for: .recordingScaleRetinaTo1x) == false)
    }

    @Test func choiceListsMatchContract() {
        #expect(RecordingSettingChoices.frameRates == [60, 50, 30, 25, 24, 15])
        #expect(RecordingSettingChoices.countdownSeconds == [3, 5, 10])
    }

    @Test func settingsPersistThroughAppStorageStyleReadWrite() {
        let settings = scratchSettings()
        settings.set(false, for: .recordingShowControls)
        settings.set(10, for: .recordingCountdownSeconds)
        settings.set(.hevc, for: .recordingCodec)
        settings.set(.filled, for: .recordingClickStyle)
        #expect(settings.value(for: .recordingShowControls) == false)
        #expect(settings.value(for: .recordingCountdownSeconds) == 10)
        #expect(settings.value(for: .recordingCodec) == .hevc)
        #expect(settings.value(for: .recordingClickStyle) == .filled)
    }
}

@Suite("RecordingSettingsPage countdown picker")
struct RecordingSettingsPageCountdownTests {
    @Test func enabledOnlyWhenCountdownIsOn() {
        #expect(RecordingSettingsPage.countdownPickerEnabled(showCountdown: true) == true)
        #expect(RecordingSettingsPage.countdownPickerEnabled(showCountdown: false) == false)
    }
}
