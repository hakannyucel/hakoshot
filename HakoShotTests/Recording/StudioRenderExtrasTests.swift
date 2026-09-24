import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R7.3: keystroke badge through the full Studio path (adapter →
/// compositor), export presets, the benchmark URL and (opt-in) the 60 s 4K
/// export benchmark.
@Suite("Studio render extras", .serialized)
struct StudioRenderExtrasTests {
    static let command: UInt64 = 0x100000

    /// 2 s 1280×720 package with ⌘Z at 0.5 s.
    static func keyedSample() async throws -> URL {
        let url = StudioTestMedia.url("keys-\(UUID().uuidString).hakostudio", directory: true)
        var spec = StudioSampleProject.Spec()
        spec.width = 1280
        spec.height = 720
        spec.fps = 30
        spec.seconds = 2
        spec.outputHeight = 720
        spec.clicks = []
        spec.motionBlur = false
        spec.keys = [RecordingKeyEvent(time: 0.5, keyCode: 0x06, modifierFlags: command, characters: "z")]
        _ = try await StudioSampleProject.make(at: url, spec: spec)
        return url
    }

    @Test func keystrokeBadgeIsExported() async throws {
        let package = try await Self.keyedSample()
        defer { try? FileManager.default.removeItem(at: package) }
        let contents = try StudioProjectFile.read(from: package)
        #expect(contents.project.keystrokes.visible, "packages with key events show the badge by default")

        let metadata = try #require(StudioProjectFile.readMetadata(for: contents.project, in: package))
        let state = StudioFrameState.make(project: contents.project, metadata: metadata, cursorPath: nil, outputTime: 1.0)
        let badge = try #require(state.keystrokeBadge)
        #expect(badge.text == "⌘Z")
        let x = Int(badge.frame.minX + badge.frame.height * 0.3), y = Int(badge.frame.midY)

        let image = try await StudioDebug.renderFrame(project: package, time: 1.0, out: StudioTestMedia.url("keys.png"))
        try? FileManager.default.removeItem(at: StudioTestMedia.url("keys.png"))
        let pill = try #require(StudioTestMedia.pixel(image, x: x, y: y))
        StudioTestMedia.log("badge pixel \(pill)")
        #expect(pill.2 < 130, "dark pill over the blue quadrant")

        // Off → the blue quadrant shows.
        var hidden = contents.project
        hidden.keystrokes.visible = false
        try StudioProjectFile.write(hidden, assets: contents.assets, to: package)
        let plain = try await StudioDebug.renderFrame(project: package, time: 1.0, out: StudioTestMedia.url("nokeys.png"))
        try? FileManager.default.removeItem(at: StudioTestMedia.url("nokeys.png"))
        let content = try #require(StudioTestMedia.pixel(plain, x: x, y: y))
        #expect(StudioTestMedia.close(content, StudioTestMedia.blue, tolerance: 20), "no badge: \(content)")
    }

    @MainActor
    @Test func exportPresetsSetRatioResolutionAndRate() async throws {
        let package = try await StudioTestMedia.sample(copy: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let studio = StudioViewModel(packageURL: package, contents: try StudioProjectFile.read(from: package))
        let model = StudioExportModel(studio: studio)

        let vertical = try #require(StudioExportModel.Preset.all.first { $0.aspectRatio == .nineSixteen })
        model.apply(vertical)
        #expect(model.outputSize == CGSize(width: 1080, height: 1920))
        #expect(model.selectedPreset == vertical)
        #expect(model.outputHeightChoices.contains(1920))

        let square = try #require(StudioExportModel.Preset.all.first { $0.aspectRatio == .square })
        model.apply(square)
        #expect(model.outputSize == CGSize(width: 1080, height: 1080))
        #expect(model.fps == 30)

        let fourK = try #require(StudioExportModel.Preset.all.first { $0.outputHeight == 2160 })
        model.apply(fourK)
        #expect(model.outputSize == CGSize(width: 3840, height: 2160))
        model.fps = 24
        #expect(model.selectedPreset == nil)
    }

    @Test func benchmarkCommandParses() throws {
        func items(_ pairs: [String: String]) -> [URLQueryItem] { pairs.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let spec = try #require(try StudioBenchmarkDebug.spec(host: "debug-benchmark-export", queryItems: items(["out": "/tmp/b.json"])))
        #expect(spec.out == URL(fileURLWithPath: "/tmp/b.json"))
        #expect(spec.project == nil && spec.seconds == 60 && spec.outputHeight == 2160 && spec.fps == 60 && spec.codec == .hevc)
        let custom = try #require(try StudioBenchmarkDebug.spec(host: "debug-benchmark-export", queryItems: items([
            "out": "/tmp/b.json", "project": "/tmp/p.hakostudio", "seconds": "10", "height": "1080", "fps": "30",
            "codec": "h264", "blur": "0", "keep": "1",
        ])))
        #expect(custom.project == URL(fileURLWithPath: "/tmp/p.hakostudio"))
        #expect(custom.seconds == 10 && custom.outputHeight == 1080 && custom.fps == 30 && custom.codec == .h264)
        #expect(!custom.motionBlur && custom.keep)
        #expect(throws: StudioDebug.ParseError.missing("out")) {
            _ = try StudioBenchmarkDebug.spec(host: "debug-benchmark-export", queryItems: [])
        }
        #expect(try StudioBenchmarkDebug.spec(host: "debug-other", queryItems: []) == nil)
    }

    /// Plan §6 R7-4. Opt-in (minutes): `TEST_RUNNER_HAKO_BENCHMARK=1`, with
    /// `TEST_RUNNER_HAKO_BENCHMARK_SECONDS` / `_HEIGHT` / `_FPS` / `_BLUR`
    /// to vary it (`_KEEP` keeps the package and the mp4). The JSON lands in `TEST_RUNNER_HAKO_BENCHMARK_OUT` (or the
    /// test temp folder).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HAKO_BENCHMARK"] != nil))
    func benchmark4KExport() async throws {
        let env = ProcessInfo.processInfo.environment
        let out = env["HAKO_BENCHMARK_OUT"].map { URL(fileURLWithPath: $0) } ?? StudioTestMedia.url("benchmark.json")
        var spec = StudioBenchmarkDebug.Spec(out: out)
        if let s = env["HAKO_BENCHMARK_SECONDS"].flatMap(Double.init) { spec.seconds = s }
        if let h = env["HAKO_BENCHMARK_HEIGHT"].flatMap(Int.init) { spec.outputHeight = h }
        if let f = env["HAKO_BENCHMARK_FPS"].flatMap(Int.init) { spec.fps = f }
        if let b = env["HAKO_BENCHMARK_BLUR"] { spec.motionBlur = b != "0" }
        spec.keep = env["HAKO_BENCHMARK_KEEP"] != nil
        let result = try await StudioBenchmarkDebug.benchmark(spec)
        StudioTestMedia.log("benchmark \(result)")
        #expect(result.width == RecordingGeometry.evenFloor(Double(spec.outputHeight) * 16 / 9))
        #expect(result.height == spec.outputHeight)
        #expect(abs(result.duration - spec.seconds) < 0.1)
        #expect(result.passed, "export \(result.exportSeconds) s for \(result.duration) s")
    }
}
