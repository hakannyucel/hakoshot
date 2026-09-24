#if DEBUG
import AVFoundation
import Foundation
import HakoKit
import os

/// DEBUG Studio export benchmark (plan §6 R7-4: a 60 s 4K Studio export in
/// under 60 s with hardware HEVC):
///
/// `debug-benchmark-export?out=<json>[&project=<pkg>&seconds=60&height=2160&fps=60&codec=hevc&blur=1&keep=0]`
///
/// Without `project` it writes a synthetic 4K package (`StudioSampleProject`:
/// quadrants, moving square, default gradient background, clicks → auto
/// zooms + motion blur, a keystroke every 5 s) next to `out`; with
/// `project` it exports that package (height / fps / codec override its
/// export settings). The export goes to a temporary mp4 (kept
/// next to `out` with `keep=1`), and the timing JSON (`Result`) to `out`.
nonisolated enum StudioBenchmarkDebug {
    static let host = "debug-benchmark-export"

    struct Spec: Sendable, Equatable {
        var project: URL?
        var out: URL
        var seconds = 60.0
        var outputHeight = 2160
        var fps = 60
        var codec: VideoCodec = .hevc
        var motionBlur = true
        var keep = false
    }

    struct Result: Codable, Sendable, Equatable {
        var project: String
        var synthetic: Bool
        var width: Int
        var height: Int
        var fps: Int
        var codec: String
        var motionBlur: Bool
        var duration: Double
        var frames: Int
        /// Synthetic package creation (not part of the benchmark).
        var setupSeconds: Double
        /// `StudioExport.export` wall time.
        var exportSeconds: Double
        /// `exportSeconds / duration` (< 1 = faster than real time).
        var realtimeFactor: Double
        var framesPerSecond: Double
        /// Average Core Image graph build per frame (`StudioRenderStats`;
        /// the GPU render and encode happen after it).
        var frameBuildMilliseconds: Double
        var fileBytes: Int64
        /// Plan §6 R7-4: export faster than the video's duration.
        var passed: Bool
    }

    // MARK: Parse

    /// `nil` for other hosts.
    static func spec(host: String, queryItems: [URLQueryItem]) throws(StudioDebug.ParseError) -> Spec? {
        guard host.lowercased() == Self.host else { return nil }
        var values: [String: String] = [:]
        for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
        guard let out = fileURL(values["out"]) else { throw .missing("out") }
        var spec = Spec(project: fileURL(values["project"]), out: out)
        if let v = values["seconds"] {
            guard let s = Double(v), s > 0 else { throw .invalid("seconds") }
            spec.seconds = s
        }
        if let v = values["height"] {
            guard let h = Int(v), h >= 144 else { throw .invalid("height") }
            spec.outputHeight = h
        }
        if let v = values["fps"] {
            guard let f = Int(v), f > 0 else { throw .invalid("fps") }
            spec.fps = f
        }
        if let v = values["codec"] {
            guard let c = VideoCodec(rawValue: v.lowercased()) else { throw .invalid("codec") }
            spec.codec = c
        }
        if let v = values["blur"] { spec.motionBlur = !["0", "false", "no"].contains(v.lowercased()) }
        if let v = values["keep"] { spec.keep = ["1", "true", "yes"].contains(v.lowercased()) }
        return spec
    }

    private static func fileURL(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if let url = URL(string: path), url.isFileURL { return url }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    // MARK: Run

    /// Runs the URL command and logs the result.
    @MainActor
    static func run(_ spec: Spec) async {
        do {
            let result = try await benchmark(spec)
            Log.studio.notice("debug: benchmark \(result.width)x\(result.height)@\(result.fps) \(result.codec, privacy: .public) \(String(format: "%.1f", result.duration), privacy: .public) s exported in \(String(format: "%.2f", result.exportSeconds), privacy: .public) s (\(String(format: "%.2f", result.realtimeFactor), privacy: .public)x real time, \(result.passed ? "pass" : "FAIL", privacy: .public)) -> \(spec.out.path, privacy: .public)")
        } catch {
            Log.studio.error("debug benchmark failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Builds (or reads) the project, exports it once, writes the JSON.
    @concurrent
    static func benchmark(_ spec: Spec) async throws -> Result {
        let fm = FileManager.default
        let folder = spec.out.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let setupStart = ContinuousClock.now
        let packageURL: URL
        let synthetic = spec.project == nil
        if let project = spec.project {
            packageURL = project
        } else {
            packageURL = folder.appendingPathComponent("benchmark-\(spec.outputHeight)p.hakostudio", isDirectory: true)
            _ = try await StudioSampleProject.make(at: packageURL, spec: sampleSpec(spec))
        }
        let setupSeconds = seconds(ContinuousClock.now - setupStart)
        defer { if synthetic, !spec.keep { try? fm.removeItem(at: packageURL) } }

        let contents = try StudioProjectFile.read(from: packageURL)
        var project = contents.project
        project.export.format = .mp4
        project.export.fps = spec.fps
        project.export.codec = spec.codec
        project.canvas.outputHeight = spec.outputHeight
        project.motionBlur.enabled = spec.motionBlur
        if synthetic { project.keystrokes.visible = true }
        let media = StudioMediaContext.load(packageURL: packageURL, project: project, assets: contents.assets)

        let movie = folder.appendingPathComponent(spec.out.deletingPathExtension().lastPathComponent + ".mp4")
        try? fm.removeItem(at: movie)
        defer { if !spec.keep { try? fm.removeItem(at: movie) } }

        _ = StudioRenderStats.shared.take()
        let exportStart = ContinuousClock.now
        _ = try await StudioExport.export(project: project, media: media, to: movie)
        let exportSeconds = seconds(ContinuousClock.now - exportStart)
        let stats = StudioRenderStats.shared.take()

        let info = try await RenderPipeline.probe(AVURLAsset(url: movie))
        let bytes = (try? fm.attributesOfItem(atPath: movie.path)[.size] as? NSNumber)?.int64Value ?? 0
        let duration = info.duration
        let frames = Int((duration * Double(project.export.outputFPS(sourceFPS: project.source.fps))).rounded())
        let result = Result(
            project: packageURL.lastPathComponent,
            synthetic: synthetic,
            width: info.pixelWidth, height: info.pixelHeight,
            fps: project.export.outputFPS(sourceFPS: project.source.fps),
            codec: info.codec?.rawValue ?? "?",
            motionBlur: project.motionBlur.enabled,
            duration: duration,
            frames: frames,
            setupSeconds: setupSeconds,
            exportSeconds: exportSeconds,
            realtimeFactor: duration > 0 ? exportSeconds / duration : 0,
            framesPerSecond: exportSeconds > 0 ? Double(frames) / exportSeconds : 0,
            frameBuildMilliseconds: stats.averageMilliseconds,
            fileBytes: bytes,
            passed: exportSeconds < duration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: spec.out, options: .atomic)
        return result
    }

    /// 4K source at the export rate, clicks spread over the length (auto
    /// zooms + motion blur), a keystroke every few seconds.
    static func sampleSpec(_ spec: Spec) -> StudioSampleProject.Spec {
        var sample = StudioSampleProject.Spec()
        sample.height = spec.outputHeight
        sample.width = RecordingGeometry.evenFloor(Double(spec.outputHeight) * 16 / 9)
        sample.scale = 2
        sample.fps = spec.fps
        sample.seconds = spec.seconds
        sample.outputHeight = spec.outputHeight
        sample.motionBlur = spec.motionBlur
        // The Studio default (gradient preset), like a real project.
        sample.background = StudioCanvas.defaultBackground.fill
        let spots: [(Double, Double)] = [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)]
        sample.clicks = stride(from: 3.0, to: max(spec.seconds - 2, 3.5), by: 8).enumerated().map { i, t in
            let spot = spots[i % spots.count]
            return StudioSampleProject.Click(time: t, x: spot.0, y: spot.1)
        }
        let command: UInt64 = 0x100000
        sample.keys = stride(from: 1.0, to: spec.seconds, by: 5).map { t in
            RecordingKeyEvent(time: t, keyCode: 0x06, modifierFlags: command, characters: "z")
        }
        return sample
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}
#endif
