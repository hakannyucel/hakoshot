import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// M7 acceptance #3: `%n` in the file name template advances per saved file.
@Suite("OutputService %n counter")
struct FileNameCounterOutputTests {
    @Test func counterAdvancesPerSavedFile() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        let settings = scratchSettings.settings
        settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        settings.set("shot-%n", for: .outputFileNameTemplate)
        settings.set(ImageFormat.png, for: .outputImageFormat)

        let service = OutputService(settings: settings)
        let names = try (0..<3).map { _ in try service.save(PostCaptureFixture.captureResult()).lastPathComponent }

        #expect(names == ["shot-1.png", "shot-2.png", "shot-3.png"])
        #expect(FileNameCounter.peek(settings: settings) == 4)
    }

    @Test func templatesWithoutCounterLeaveItAlone() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        let settings = scratchSettings.settings
        settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        settings.set(FileNameTemplate.default.pattern, for: .outputFileNameTemplate)

        _ = try OutputService(settings: settings).save(PostCaptureFixture.captureResult())
        #expect(FileNameCounter.peek(settings: settings) == 1)
    }
}
