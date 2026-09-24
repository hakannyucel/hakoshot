#if DEBUG
import AppKit
import AVFoundation
import CoreVideo
import Foundation
import HakoKit
import ImageIO
import os
import UniformTypeIdentifiers

/// DEBUG Studio commands (plan §7 R6.4 / R7.2), no UI needed except the
/// snapshot:
///
/// - `debug-render-studio-frame?project=<pkg>&time=<s>&out=<png>[&height=<px>]`
///   — the composited frame at timeline time `time` (export quality).
/// - `debug-export-studio?project=<pkg>&out=<file>[&format=mp4|gif]` — full
///   export; `format` overrides the project's.
/// - `debug-studio-snapshot?project=<pkg>&out=<png>[&close=0]` — opens the
///   Studio editor and writes its window content (preview frame included).
/// - `debug-studio-zoom?project=<pkg>&add=start,end,scale,x,y&out=<pkg>` —
///   adds a manual zoom segment (fixed focus `x, y` in `0…1`) and saves to
///   `out` (may equal `project`).
/// - `debug-studio-sample?out=<pkg>[&seconds=5&width=1920&height=1080&fps=60&click=t,x,y]`
///   — writes a synthetic Studio package (four colored quadrants, cursor
///   track, clicks, auto zooms planned).
///
/// Results and elapsed times go to the log (`category: studio`).
nonisolated enum StudioDebug {
    enum ParseError: Error, Equatable, CustomStringConvertible {
        case missing(String)
        case invalid(String)

        var description: String {
            switch self {
            case .missing(let key): "missing \(key)"
            case .invalid(let key): "invalid \(key)"
            }
        }
    }

    enum Command: Sendable, Equatable {
        case renderFrame(project: URL, time: Double, out: URL, height: Int?)
        case export(project: URL, out: URL, format: VideoEditOutputFormat?)
        case snapshot(project: URL, out: URL, close: Bool)
        case zoom(project: URL, segment: ZoomSegment, out: URL)
        case sample(out: URL, spec: StudioSampleProject.Spec)

        static let hosts = [
            "debug-render-studio-frame", "debug-export-studio", "debug-studio-snapshot",
            "debug-studio-zoom", "debug-studio-sample",
        ]

        /// `nil` for hosts this type doesn't handle.
        init?(host: String, queryItems: [URLQueryItem]) throws(ParseError) {
            var values: [String: String] = [:]
            for item in queryItems { if let value = item.value { values[item.name.lowercased()] = value } }
            func url(_ key: String) throws(ParseError) -> URL {
                guard let url = Self.fileURL(values[key]) else { throw .missing(key) }
                return url
            }
            switch host.lowercased() {
            case "debug-render-studio-frame":
                guard let time = Double(values["time"] ?? values["t"] ?? "") else { throw .missing("time") }
                let height = try values["height"].map { value throws(ParseError) -> Int in
                    guard let h = Int(value), h > 0 else { throw .invalid("height") }
                    return h
                }
                self = .renderFrame(project: try url("project"), time: time, out: try url("out"), height: height)
            case "debug-export-studio":
                let format = try values["format"].map { value throws(ParseError) -> VideoEditOutputFormat in
                    guard let f = VideoEditOutputFormat(rawValue: value.lowercased()) else { throw .invalid("format") }
                    return f
                }
                self = .export(project: try url("project"), out: try url("out"), format: format)
            case "debug-studio-snapshot":
                let close = values["close"].map { !["0", "false", "no"].contains($0.lowercased()) } ?? true
                self = .snapshot(project: try url("project"), out: try url("out"), close: close)
            case "debug-studio-zoom":
                guard let add = values["add"] else { throw .missing("add") }
                let parts = add.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 5 || parts.count == 3, parts[1] > parts[0] else { throw .invalid("add") }
                let focus: ZoomFocus = parts.count == 5 ? .fixed(x: parts[3], y: parts[4]) : .followCursor
                let segment = ZoomSegment(start: parts[0], end: parts[1], scale: parts[2], focus: focus, isManual: true)
                let project = try url("project")
                self = .zoom(project: project, segment: segment, out: Self.fileURL(values["out"]) ?? project)
            case "debug-studio-sample":
                var spec = StudioSampleProject.Spec()
                if let s = values["seconds"].flatMap(Double.init) { spec.seconds = s }
                if let w = values["width"].flatMap(Int.init) { spec.width = w }
                if let h = values["height"].flatMap(Int.init) { spec.height = h }
                if let f = values["fps"].flatMap(Int.init) { spec.fps = f }
                if let click = values["click"] {
                    let p = click.split(separator: ",").compactMap { Double($0) }
                    guard p.count == 3 else { throw .invalid("click") }
                    spec.clicks = [.init(time: p[0], x: p[1], y: p[2])]
                }
                self = .sample(out: try url("out"), spec: spec)
            default:
                return nil
            }
        }

        private static func fileURL(_ path: String?) -> URL? {
            guard let path, !path.isEmpty else { return nil }
            if let url = URL(string: path), url.isFileURL { return url }
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
    }

    // MARK: Run

    /// Runs `command`, logging the result and elapsed time.
    @MainActor
    static func run(_ command: Command) async {
        let started = ContinuousClock.now
        do {
            let summary: String
            switch command {
            case let .renderFrame(project, time, out, height):
                let image = try await renderFrame(project: project, time: time, out: out, outputHeight: height)
                summary = "frame \(image.width)x\(image.height) at \(time) s -> \(out.path)"
            case let .export(project, out, format):
                let url = try await export(project: project, out: out, format: format)
                summary = "export -> \(url.path)"
            case let .snapshot(project, out, close):
                let size = try await snapshot(project: project, out: out, close: close)
                summary = "snapshot \(Int(size.width))x\(Int(size.height)) -> \(out.path)"
            case let .zoom(project, segment, out):
                let saved = try addZoom(project: project, segment: segment, out: out)
                summary = "zoom added (\(saved.zoom.segments.count) segments) -> \(out.path)"
            case let .sample(out, spec):
                let project = try await StudioSampleProject.make(at: out, spec: spec)
                summary = "sample \(project.source.pixelWidth)x\(project.source.pixelHeight) \(spec.seconds) s, \(project.zoom.segments.count) zooms -> \(out.path)"
            }
            let elapsed = ContinuousClock.now - started
            Log.studio.notice("debug: \(summary, privacy: .public) in \(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))), privacy: .public)")
        } catch {
            Log.studio.error("debug studio command failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Commands

    /// Renders one frame at timeline time `time` and writes it as PNG.
    @discardableResult
    static func renderFrame(project packageURL: URL, time: Double, out: URL, outputHeight: Int? = nil) async throws -> CGImage {
        let contents = try StudioProjectFile.read(from: packageURL)
        let media = StudioMediaContext.load(packageURL: packageURL, project: contents.project, assets: contents.assets)
        let image = try await StudioExport.frameImage(project: contents.project, media: media, outputTime: time, outputHeight: outputHeight)
        try writePNG(image, to: out)
        return image
    }

    /// Exports the package (optionally overriding the format).
    @discardableResult
    static func export(project packageURL: URL, out: URL, format: VideoEditOutputFormat? = nil) async throws -> URL {
        let contents = try StudioProjectFile.read(from: packageURL)
        var project = contents.project
        if let format { project.export.format = format }
        let media = StudioMediaContext.load(packageURL: packageURL, project: project, assets: contents.assets)
        return try await StudioExport.export(project: project, media: media, to: out)
    }

    /// Adds `segment` (manual) and saves the package to `out`.
    @discardableResult
    static func addZoom(project packageURL: URL, segment: ZoomSegment, out: URL) throws -> StudioProject {
        let contents = try StudioProjectFile.read(from: packageURL)
        let state = StudioReducer.reduce(StudioEditorState(project: contents.project), .addZoomSegment(segment))
        let same = out.standardizedFileURL == packageURL.standardizedFileURL
        try StudioProjectFile.write(
            state.project, assets: contents.assets, to: out,
            mediaSource: same ? nil : packageURL.appendingPathComponent(StudioProjectFile.mediaDirectoryName)
        )
        return state.project
    }

    /// Opens the editor, waits for the preview, writes the window content.
    @MainActor
    static func snapshot(project packageURL: URL, out: URL, close: Bool) async throws -> CGSize {
        guard let controller = StudioWindowController.open(url: packageURL) else {
            throw RenderError.cannotRead("could not open \(packageURL.lastPathComponent)")
        }
        _ = await controller.model.playback.waitUntilReady(timeout: .seconds(8))
        for _ in 0..<60 where controller.model.thumbnails.isEmpty {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard let image = await controller.snapshotImage() else {
            throw RenderError.cannotWrite("snapshot failed")
        }
        try writePNG(image, to: out)
        if close { controller.closeWithoutSaving() }
        return CGSize(width: image.width, height: image.height)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw RenderError.cannotWrite(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RenderError.cannotWrite(url.path) }
    }
}

// MARK: - Synthetic project

/// A synthetic Studio package for tests and smoke runs: a video of four
/// solid quadrants (top-left red, top-right green, bottom-left blue,
/// bottom-right yellow) with a small white square moving inside the
/// bottom-right quadrant, a cursor track that glides to each click, the
/// clicks in `events.json`, and auto zooms planned by `ZoomPlanner`.
nonisolated enum StudioSampleProject {
    struct Click: Sendable, Equatable {
        var time: Double
        /// Unit coordinates of the recording (`0…1`, y down).
        var x: Double
        var y: Double
    }

    struct Spec: Sendable, Equatable {
        var width = 1920
        var height = 1080
        /// Pixels per point (the recording rect is `width / scale` points).
        var scale = 2.0
        var fps = 60
        var seconds = 5.0
        var clicks: [Click] = [Click(time: 3, x: 0.25, y: 0.25)]
        var background: BackgroundFill = .solid(StudioSampleProject.backgroundColor)
        var aspectRatio: RecordingAspectRatio = .sixteenNine
        var outputHeight = 1080
        var motionBlur = true
        /// Key events for `events.json` (keystroke badge).
        var keys: [RecordingKeyEvent] = []
    }

    static let backgroundColor = RGBAColor(hex: "#336699") ?? .black

    /// sRGB 8-bit quadrant colors: top-left, top-right, bottom-left, bottom-right.
    static let quadrantColors: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (230, 40, 40), (40, 200, 60), (40, 80, 230), (240, 210, 40),
    ]

    /// Writes the package at `packageURL` (replaced) and returns its project.
    @concurrent
    static func make(at packageURL: URL, spec: Spec = Spec()) async throws -> StudioProject {
        let fm = FileManager.default
        let parent = packageURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let raw = parent.appendingPathComponent(".studio-sample-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: raw, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: raw) }
        if fm.fileExists(atPath: packageURL.path) { try fm.removeItem(at: packageURL) }

        try await writeVideo(to: raw.appendingPathComponent(StudioMediaFiles.defaultScreen), spec: spec)

        let pointW = Double(spec.width) / spec.scale, pointH = Double(spec.height) / spec.scale
        var clicks: [RecordingClickEvent] = []
        for click in spec.clicks {
            clicks.append(RecordingClickEvent(time: click.time, x: click.x * pointW, y: click.y * pointH, isDown: true))
            clicks.append(RecordingClickEvent(time: click.time + 0.08, x: click.x * pointW, y: click.y * pointH, isDown: false))
        }
        let metadata = RecordingMetadata(
            hostTimeOrigin: 1000,
            geometry: RecordingGeometryInfo(rect: CGRect(x: 0, y: 0, width: pointW, height: pointH), displayID: 1,
                                            scale: spec.scale, pixelWidth: spec.width, pixelHeight: spec.height),
            clicks: clicks,
            keys: spec.keys,
            cursorBakedIn: false
        )
        try metadata.jsonData().write(to: raw.appendingPathComponent(StudioMediaFiles.defaultEvents))
        let samples = cursorSamples(spec: spec, pointSize: CGSize(width: pointW, height: pointH))
        try CursorTrackCodec.encode(samples).write(to: raw.appendingPathComponent(StudioMediaFiles.defaultCursor))

        var background = StudioCanvas.defaultBackground
        background.fill = spec.background
        let defaults = StudioProjectDefaults(motionBlur: spec.motionBlur, background: background,
                                             aspectRatio: spec.aspectRatio, outputHeight: spec.outputHeight)
        let source = StudioSource(pixelWidth: spec.width, pixelHeight: spec.height, pointWidth: pointW, pointHeight: pointH,
                                  fps: Double(spec.fps), duration: spec.seconds)
        var project = try StudioProjectFile.create(from: raw, metadata: metadata, source: source, defaults: defaults,
                                                   at: packageURL, transfer: .move)
        project.export.fps = spec.fps
        project.zoom.segments = ZoomPlanner.regenerated(project: project, metadata: metadata)
        try StudioProjectFile.write(project, to: packageURL)
        return project
    }

    /// The cursor rests at the center, glides to each click over the second
    /// before it, then rests on the click point. 60 Hz.
    static func cursorSamples(spec: Spec, pointSize: CGSize) -> [CursorSample] {
        let rate = 60.0
        let count = Int(spec.seconds * rate) + 1
        var targets: [(time: Double, x: Double, y: Double)] = [(0, 0.5, 0.5)]
        for click in spec.clicks.sorted(by: { $0.time < $1.time }) {
            targets.append((click.time, click.x, click.y))
        }
        var samples: [CursorSample] = []
        samples.reserveCapacity(count)
        for i in 0..<count {
            let t = Double(i) / rate
            var x = targets[0].x, y = targets[0].y
            for target in targets.dropFirst() {
                let begin = target.time - 1.0, end = target.time - 0.1
                if t >= end {
                    x = target.x
                    y = target.y
                } else if t > begin {
                    let p = (t - begin) / (end - begin)
                    x += (target.x - x) * p
                    y += (target.y - y) * p
                }
            }
            samples.append(CursorSample(time: t, x: Float(x * pointSize.width), y: Float(y * pointSize.height)))
        }
        return samples
    }

    // MARK: Video

    private static func writeVideo(to url: URL, spec: Spec) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: spec.width,
            AVVideoHeightKey: spec.height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: spec.width,
            kCVPixelBufferHeightKey as String: spec.height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw RenderError.cannotWrite("sample writer: \(String(describing: writer.error))") }
        writer.startSession(atSourceTime: .zero)
        let total = Int(spec.seconds * Double(spec.fps))
        let pump = FramePump(input: input, adaptor: adaptor, spec: spec, total: total)
        await pump.run()
        await writer.finishWriting()
        guard writer.status == .completed else { throw RenderError.cannotWrite("sample writer: \(String(describing: writer.error))") }
    }

    private final class FramePump: @unchecked Sendable {
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let spec: Spec
        let total: Int
        var index = 0

        init(input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, spec: Spec, total: Int) {
            self.input = input
            self.adaptor = adaptor
            self.spec = spec
            self.total = total
        }

        func run() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                input.requestMediaDataWhenReady(on: DispatchQueue(label: "studio.sample.video")) { [self] in
                    while input.isReadyForMoreMediaData {
                        guard index < total, let pool = adaptor.pixelBufferPool, let buffer = frame(index, pool: pool) else {
                            input.markAsFinished()
                            continuation.resume()
                            return
                        }
                        _ = adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(spec.fps)))
                        index += 1
                    }
                }
            }
        }

        private func frame(_ index: Int, pool: CVPixelBufferPool) -> CVPixelBuffer? {
            var out: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out)
            guard let buffer = out else { return nil }
            CVPixelBufferLockBaseAddress(buffer, [])
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            let w = spec.width, h = spec.height
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return nil }
            // CG origin is bottom-left: top-left quadrant = (0, h/2).
            let halfW = CGFloat(w / 2), halfH = CGFloat(h / 2)
            let rects = [
                CGRect(x: 0, y: halfH, width: halfW, height: CGFloat(h) - halfH),
                CGRect(x: halfW, y: halfH, width: CGFloat(w) - halfW, height: CGFloat(h) - halfH),
                CGRect(x: 0, y: 0, width: halfW, height: halfH),
                CGRect(x: halfW, y: 0, width: CGFloat(w) - halfW, height: halfH),
            ]
            for (rect, color) in zip(rects, StudioSampleProject.quadrantColors) {
                context.setFillColor(red: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255, blue: CGFloat(color.b) / 255, alpha: 1)
                context.fill(rect)
            }
            // Moving square inside the bottom-right quadrant.
            let side = halfH / 4
            let travel = max(halfW - side - 16, 1)
            let x = halfW + 8 + CGFloat((index * 6) % Int(travel))
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            context.fill(CGRect(x: x, y: halfH / 3, width: side, height: side))
            return buffer
        }
    }
}
#endif
