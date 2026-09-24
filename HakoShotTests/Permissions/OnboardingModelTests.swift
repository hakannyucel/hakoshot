import CoreGraphics
import HakoKit
import Testing
@testable import HakoShot

@Suite("Onboarding")
@MainActor
struct OnboardingModelTests {
    @Test func stepsRunInPlanOrder() {
        #expect(OnboardingStep.allCases == [.welcome, .screenRecording, .accessibility, .shortcuts, .launchAtLogin, .done])
    }

    @Test func nextAndBackStopAtTheEnds() {
        let model = OnboardingModel(permissions: PermissionsService(), step: .welcome)
        #expect(model.isFirst)
        model.back()
        #expect(model.step == .welcome)
        for _ in 0..<10 { model.next() }
        #expect(model.step == .done)
        #expect(model.isLast)
        model.back()
        #expect(model.step == .launchAtLogin)
    }

    @Test func readsTheFiveSystemScreenshotShortcuts() {
        let model = OnboardingModel(permissions: PermissionsService(), step: .shortcuts)
        #expect(model.systemShortcuts.map(\.id) == [28, 29, 30, 31, 184])
    }
}

@Suite("Editor Annotate defaults")
@MainActor
struct EditorAnnotateDefaultsTests {
    private func makeImage() throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: 40, height: 30, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return try #require(context.makeImage())
    }

    @Test func editorStartsWithAnnotateDefaultsAndRemembersChanges() throws {
        let scratch = PostCaptureFixture.ScratchSettings()
        defer { scratch.cleanup() }
        let settings = scratch.settings
        settings.set(false, for: .annotateRememberLastUsed)
        settings.set(0, for: .annotateStrokeWidthIndex)
        settings.set(false, for: .annotateShadow)

        let model = EditorViewModel(image: try makeImage(), scale: 1, mode: .area, settings: settings)
        #expect(model.store.toolSettings.strokePresetIndex == 0)
        #expect(model.store.toolSettings.shadow == false)

        settings.set(true, for: .annotateRememberLastUsed)
        model.setColor(RGBAColor(red: 0, green: 1, blue: 0, alpha: 1))
        let next = EditorViewModel(image: try makeImage(), scale: 1, mode: .area, settings: settings)
        #expect(next.store.toolSettings.color == RGBAColor(red: 0, green: 1, blue: 0, alpha: 1))
    }
}
