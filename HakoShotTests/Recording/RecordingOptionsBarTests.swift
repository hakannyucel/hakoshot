import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

// R1.1 pre-record HUD: key → format/profile mapping, ratio presets on a
// size, settings binding, and the DEBUG snapshot's size against the tokens.

@Suite("Recording HUD: format choice")
struct RecordFormatChoiceTests {
    @Test func returnKeyMapping() {
        #expect(RecordFormatChoice.forConfirm(modifiers: []) == .video)
        #expect(RecordFormatChoice.forConfirm(modifiers: .option) == .gif)
        #expect(RecordFormatChoice.forConfirm(modifiers: .shift) == .studio)
        // ⇧ wins over ⌥; ⌘ / ⌃ / caps lock are ignored.
        #expect(RecordFormatChoice.forConfirm(modifiers: [.shift, .option]) == .studio)
        #expect(RecordFormatChoice.forConfirm(modifiers: .command) == .video)
        #expect(RecordFormatChoice.forConfirm(modifiers: [.control, .option]) == .gif)
        #expect(RecordFormatChoice.forConfirm(modifiers: [.capsLock, .numericPad]) == .video)
    }

    @Test func formatAndProfile() {
        #expect(RecordFormatChoice.video.format == .video)
        #expect(RecordFormatChoice.video.profile == .classic)
        #expect(RecordFormatChoice.gif.format == .gif)
        #expect(RecordFormatChoice.gif.profile == .classic)
        #expect(RecordFormatChoice.studio.format == .video)
        #expect(RecordFormatChoice.studio.profile == .studio)
    }

    @Test func menuOrderAndGlyphs() {
        #expect(RecordFormatChoice.menuOrder.map(\.title) == ["Record Video", "Record GIF", "Record in Studio Mode"])
        #expect(RecordFormatChoice.menuOrder.map(\.shortcutGlyph) == ["↵", "⌥↵", "⇧↵"])
    }

    @Test func overrides() {
        #expect(RecordFormatChoice.video.overrides.isEmpty)
        #expect(RecordFormatChoice.gif.overrides.isEmpty)
        let base = RecordingOptions(quality: .medium, showsCursor: true)
        let studio = RecordFormatChoice.studio.overrides.applied(to: base)
        #expect(studio.showsCursor == false)
        #expect(studio.quality == .ultra)
        #expect(studio.fps == base.fps)
        #expect(RecordFormatChoice.video.overrides.applied(to: base) == base)
    }
}

@Suite("Recording HUD: size and ratio")
@MainActor
struct RecordingHUDRatioTests {
    @Test func hudPresetsIncludeFiveFour() {
        let presets = RecordingHUDModel.ratioPresets
        #expect(presets.map(\.title) == ["Freeform", "1:1", "4:3", "5:4", "3:2", "16:9", "16:10", "9:16"])
        #expect(presets.first == .freeform)
        #expect(AspectRatioPreset(RecordingAspectRatio.fiveFour) == .fixed(width: 5, height: 4))
        #expect(AspectRatioPreset(RecordingAspectRatio.freeform) == .freeform)
    }

    @Test func presetAppliedToSelection() {
        let size = CGSize(width: 1000, height: 300)
        #expect(SizeBarMath.fitted(size, to: AspectRatioPreset.fixed(width: 5, height: 4).ratio) == CGSize(width: 1000, height: 800))
        #expect(SizeBarMath.fitted(size, to: AspectRatioPreset.fixed(width: 16, height: 9).ratio) == CGSize(width: 1000, height: 563))
        #expect(SizeBarMath.fitted(size, to: AspectRatioPreset.fixed(width: 9, height: 16).ratio) == CGSize(width: 1000, height: 1778))
        #expect(SizeBarMath.fitted(size, to: AspectRatioPreset.freeform.ratio) == size)
        // Not enough room below: keep the ratio at the available height.
        #expect(SizeBarMath.fitted(size, to: 5.0 / 4.0, maxHeight: 400) == CGSize(width: 500, height: 400))
    }

    @Test func typedSizeUnderRatio() {
        let fiveFour = AspectRatioPreset.fixed(width: 5, height: 4).ratio
        let current = CGSize(width: 640, height: 360)
        #expect(SizeBarMath.submittedSize(widthText: "1000", heightText: "360", current: current, ratio: fiveFour, editedWidth: true)
            == CGSize(width: 1000, height: 800))
        #expect(SizeBarMath.submittedSize(widthText: "640", heightText: " 400 ", current: current, ratio: fiveFour, editedWidth: false)
            == CGSize(width: 500, height: 400))
        #expect(SizeBarMath.submittedSize(widthText: "801.4", heightText: "600", current: current, ratio: nil, editedWidth: true)
            == CGSize(width: 801, height: 600))
        #expect(SizeBarMath.submittedSize(widthText: "abc", heightText: "", current: current, ratio: nil, editedWidth: true)
            == current)
        #expect(SizeBarMath.submittedSize(widthText: "0", heightText: "0", current: current, ratio: nil, editedWidth: true) == nil)
    }
}

@Suite("Recording HUD: settings binding", .serialized)
@MainActor
struct RecordingHUDSettingsTests {
    static func settings() -> (AppSettings, UserDefaults, String) {
        let suite = "com.hakanyucel.hakoshot.tests.hud.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (AppSettings(defaults: defaults), defaults, suite)
    }

    @Test func readsDefaultsAndStoredValues() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.set(true, for: .recordingSystemAudio)
        let model = RecordingHUDModel(settings: settings)
        #expect(model.isOn(.systemAudio))
        #expect(!model.isOn(.microphone))
        #expect(model.isOn(.highlightClicks))   // default on
        #expect(!model.isOn(.showKeystrokes))   // default off
        #expect(model.isOn(.showCursor))
        #expect(!model.isOn(.countdown))
        #expect(model.microphoneDeviceID.isEmpty)
    }

    @Test func togglesWriteTheirKeys() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings)
        let expected: [(RecordingHUDToggle, SettingsKey<Bool>)] = [
            (.microphone, .recordingMicrophoneEnabled), (.systemAudio, .recordingSystemAudio),
            (.highlightClicks, .recordingHighlightClicks), (.showKeystrokes, .recordingShowKeystrokes),
            (.showCursor, .recordingShowCursor), (.countdown, .recordingShowCountdown),
            (.doNotDisturb, .recordingDoNotDisturb), (.hideDesktopIcons, .recordingHideDesktopIcons),
        ]
        for (toggle, key) in expected {
            let before = settings.value(for: key)
            model.toggle(toggle)
            #expect(settings.value(for: key) == !before, "\(toggle.rawValue)")
            #expect(model.isOn(toggle) == !before)
        }
        // A fresh model (next HUD) sees the same values.
        let next = RecordingHUDModel(settings: settings)
        for (toggle, key) in expected { #expect(next.isOn(toggle) == settings.value(for: key)) }
    }

    /// Without a camera the toggle stays a dimmed placeholder (R4.I; the
    /// camera cases are in `RecordingR45IntegrationTests`).
    @Test func cameraIsPlaceholderWithoutCamera() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings, hasCamera: { false })
        model.toggle(.camera)
        #expect(!settings.value(for: .recordingCameraEnabled))
        #expect(!model.isOn(.camera))
    }

    @Test func togglesReachRecordingOptions() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings)
        model.set(.microphone, true)
        model.set(.systemAudio, true)
        model.set(.showKeystrokes, true)
        model.set(.highlightClicks, false)
        model.set(.countdown, true)
        let options = RecordingHUDSelection(choice: .video).options(settings: settings)
        #expect(options.microphone == .systemDefault)
        #expect(options.capturesSystemAudio)
        #expect(options.showsKeystrokes)
        #expect(!options.highlightsClicks)
        #expect(options.countdownSeconds == 3)
        #expect(options.showsCursor)
        let studio = RecordingHUDSelection(choice: .studio).options(settings: settings)
        #expect(!studio.showsCursor)
        #expect(studio.quality == .ultra)
        #expect(studio.capturesSystemAudio)
    }

    @Test func microphoneDevice() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        settings.set("dev-1", for: .recordingMicrophoneDeviceID)
        let model = RecordingHUDModel(settings: settings)
        #expect(model.microphoneDeviceID == "dev-1")
        model.selectMicrophone(deviceID: "")
        #expect(settings.value(for: .recordingMicrophoneDeviceID) == "")
        #expect(settings.value(for: .recordingMicrophoneEnabled))
    }

    @Test func sizeTexts() {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RecordingHUDModel(settings: settings)
        model.selectionSize = CGSize(width: 640.4, height: 359.6)
        model.updateSizeTexts()
        #expect(model.widthText == "640")
        #expect(model.heightText == "360")
        model.isEditingSize = true
        model.selectionSize = CGSize(width: 10, height: 10)
        model.updateSizeTexts()
        #expect(model.widthText == "640")
        model.openMenu = .ratio
        #expect(model.showsRatioMenu)
    }

    /// The DEBUG snapshot is two pills + gap + shadow margins tall (tokens).
    @Test func snapshotMatchesTokens() async throws {
        let (settings, defaults, suite) = Self.settings()
        defer { defaults.removePersistentDomain(forName: suite) }
        let url = FileManager.default.temporaryDirectory.appending(path: "hud-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = try #require(await RecordingHUDDebug.run(.init(snapshot: url, hold: 0.1), settings: settings))
        let rep = try #require(NSImage(contentsOf: url)?.representations.first)
        #expect(CGFloat(rep.pixelsHigh) == snapshot.pixelSize.height)
        let expectedHeight = Tokens.Recording.hudPillHeight * 2 + Tokens.Recording.hudPillGap + Tokens.Recording.hudShadowMargin * 2
        #expect(abs(snapshot.pointSize.height - expectedHeight) < 0.5, "height \(snapshot.pointSize.height) pt, expected \(expectedHeight)")
        let scale = snapshot.pixelSize.height / snapshot.pointSize.height
        #expect(scale >= 1 && abs(scale - scale.rounded()) < 0.01)
    }
}
