import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R6.4 Studio editor + R7.2 zoom lane (kayit-teknik-plan §6 R6 / R7
/// acceptance, §7 R6.4). Synthetic packages from `StudioSampleProject`:
/// four solid quadrants (TL red, TR green, BL blue, BR yellow), a click in
/// the top-left quadrant at t = 3 s, solid `#336699` background, 16:9 1080p.
@Suite("Studio editor", .serialized)
struct StudioEditorTests {
    // MARK: Frames (§6 R6 acceptance 1, R7 acceptance 1–2)

    @Test func frameAtOneSecondShowsBackgroundCornerAndContentCenter() async throws {
        let package = try await StudioTestMedia.sample()
        let out = StudioTestMedia.url("frame-1.0.png")
        let image = try await StudioDebug.renderFrame(project: package, time: 1.0, out: out)
        defer { try? FileManager.default.removeItem(at: out) }
        #expect(image.width == 1920 && image.height == 1080)
        #expect(FileManager.default.fileExists(atPath: out.path))

        let corner = try #require(StudioTestMedia.pixel(image, x: 3, y: 3))
        StudioTestMedia.log("t=1.0 corner \(corner)")
        #expect(StudioTestMedia.close(corner, (51, 102, 153), tolerance: 6), "corner is the background color")

        // Center area is content: just above-left of the center is the
        // top-left quadrant (no zoom yet at t = 1).
        let cx = 1920 / 2 - 24, cy = 1080 / 2 - 24
        let center = try #require(StudioTestMedia.pixel(image, x: cx, y: cy))
        StudioTestMedia.log("t=1.0 center-ish \(center)")
        #expect(StudioTestMedia.close(center, StudioTestMedia.red, tolerance: 20), "center shows content")
        #expect(!StudioTestMedia.close(center, (51, 102, 153), tolerance: 20))
    }

    @Test func zoomOnTopLeftClickCentersTopLeftContent() async throws {
        let package = try await StudioTestMedia.sample()
        let project = try StudioProjectFile.read(from: package).project
        #expect(project.zoom.segments.contains { !$0.isManual && $0.contains(3) }, "auto zoom around the click")

        let zoomed = try await StudioDebug.renderFrame(project: package, time: 3.5, out: StudioTestMedia.url("frame-3.5.png"))
        // The cursor rests on the click (the focus), i.e. at the output
        // center; probe just above-left of its hot spot.
        let cx = zoomed.width / 2 - 40, cy = zoomed.height / 2 - 40
        let center = try #require(StudioTestMedia.pixel(zoomed, x: cx, y: cy))
        StudioTestMedia.log("t=3.5 center \(center)")
        #expect(StudioTestMedia.close(center, StudioTestMedia.red, tolerance: 20), "zoomed onto the top-left quadrant")
        // Zoomed 2× into the top-left quadrant: the content's right half is red too.
        let right = try #require(StudioTestMedia.pixel(zoomed, x: zoomed.width * 3 / 4, y: zoomed.height / 2))
        #expect(StudioTestMedia.close(right, StudioTestMedia.red, tolerance: 20))

        let full = try await StudioDebug.renderFrame(project: package, time: 0, out: StudioTestMedia.url("frame-0.png"))
        // Whole frame at t = 0: each quadrant visible at its place inside the padding.
        let w = full.width, h = full.height
        let probes: [(Int, Int, (Int, Int, Int))] = [
            (w / 4, h / 4, StudioTestMedia.red), (w * 3 / 4, h / 4, StudioTestMedia.green),
            (w / 4, h * 3 / 4, StudioTestMedia.blue), (w * 3 / 4 + 120, h * 3 / 4 - 120, StudioTestMedia.yellow),
        ]
        for (x, y, expected) in probes {
            let p = try #require(StudioTestMedia.pixel(full, x: x, y: y))
            StudioTestMedia.log("t=0 (\(x),\(y)) \(p)")
            #expect(StudioTestMedia.close(p, expected, tolerance: 20), "t=0 shows the full frame at (\(x), \(y))")
        }
        for name in ["frame-3.5.png", "frame-0.png"] { try? FileManager.default.removeItem(at: StudioTestMedia.url(name)) }
    }

    // MARK: Motion blur (§6 R7 acceptance 3)

    @Test func motionBlurMixesEdgePixelsDuringZoomTransition() async throws {
        let package = try await StudioTestMedia.sample()
        let contents = try StudioProjectFile.read(from: package)
        var project = contents.project
        project.motionBlur = StudioMotionBlur(enabled: true, intensity: 1)
        let media = StudioMediaContext.load(packageURL: package, project: project)
        let segment = try #require(project.zoom.segments.first { $0.contains(3) })
        let t = segment.start + project.zoom.speed.transitionDuration * 0.5

        let blurred = StudioRenderAdapter(project: project, media: media, fps: 30, blur: .standard)
        let plan = blurred.blurPlan(outputTime: t)
        StudioTestMedia.log("blur plan at \(t): \(plan.count) samples, \(String(format: "%.1f", plan.displacement)) px")
        #expect(plan.isBlurred)

        var sharpProject = project
        sharpProject.motionBlur.enabled = false
        let sharp = StudioRenderAdapter(project: sharpProject, media: media, fps: 30)

        let source = StudioTestMedia.quadrantImage(width: project.source.pixelWidth, height: project.source.pixelHeight)
        let blurredImage = try #require(StudioFrameRenderer.makeCGImage(blurred.render(screen: source, outputTime: t)))
        let sharpImage = try #require(StudioFrameRenderer.makeCGImage(sharp.render(screen: source, outputTime: t)))
        let y = blurredImage.height * 3 / 10
        let mixedBlurred = StudioTestMedia.mixedRedGreenCount(blurredImage, row: y)
        let mixedSharp = StudioTestMedia.mixedRedGreenCount(sharpImage, row: y)
        StudioTestMedia.log("mixed red/green pixels on row \(y): blurred \(mixedBlurred), sharp \(mixedSharp)")
        #expect(mixedBlurred >= 4)
        #expect(mixedBlurred > mixedSharp)
    }

    // MARK: Export (§6 R6 acceptance 2)

    @Test func exportMatchesCanvasSizeAndTrimDuration() async throws {
        let package = try await StudioTestMedia.sample()
        var project = try StudioProjectFile.read(from: package).project
        project.edit.trim = EditTimeRange(start: 0.5, end: 3.5)
        project.export.fps = 30
        let media = StudioMediaContext.load(packageURL: package, project: project)
        let out = StudioTestMedia.url("export.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let started = ContinuousClock.now
        _ = try await StudioExport.export(project: project, media: media, to: out)
        let elapsed = ContinuousClock.now - started

        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        StudioTestMedia.log("export 3.0 s trim: \(Int(size.width))x\(Int(size.height)), \(String(format: "%.3f", duration)) s, took \(elapsed)")
        #expect(size == CGSize(width: 1920, height: 1080))
        #expect(abs(duration - 3.0) <= 1.0 / 30 + 1e-3)
    }

    @Test func exportGIFUsesGIFSize() async throws {
        let package = try await StudioTestMedia.sample()
        var project = try StudioProjectFile.read(from: package).project
        project.edit.trim = EditTimeRange(start: 0, end: 1)
        project.export.format = .gif
        project.export.gif = GIFExportOptions(fps: 10, width: 400, optimize: true, quality: 0.5)
        let media = StudioMediaContext.load(packageURL: package, project: project)
        let out = StudioTestMedia.url("export.gif")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await StudioExport.export(project: project, media: media, to: out)
        let source = try #require(CGImageSourceCreateWithURL(out as CFURL, nil))
        let first = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        StudioTestMedia.log("gif \(first.width)x\(first.height), \(CGImageSourceGetCount(source)) frames")
        #expect(abs(first.width - 400) <= 2 && abs(first.height - 225) <= 2, "GIF width 400 (even canvas rounding)")
        #expect(CGImageSourceGetCount(source) >= 1)
    }

    // MARK: Zoom lane (R7.2)

    @MainActor
    @Test func zoomLaneActionsAreUndoable() async throws {
        let package = try await StudioTestMedia.sample(copy: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let model = try StudioViewModel.load(url: package)
        model.autosaveDelay = .seconds(3600)
        defer { model.tearDown() }
        let initial = model.zoomSegments
        let auto = try #require(initial.first { !$0.isManual })

        // Add by double-click.
        let added = model.addZoom(atSourceTime: 1.0)
        #expect(model.zoomSegments.count == initial.count + 1)
        #expect(model.selectedZoomID == added.id)
        #expect(model.zoomSegments.first { $0.id == added.id }?.isManual == true)
        model.undo()
        #expect(model.zoomSegments == initial)
        model.redo()
        #expect(model.zoomSegments.count == initial.count + 1)

        // Move by dragging: several updates, one undo step.
        let depth = model.store.undoDepth
        model.beginInteraction("Move Zoom")
        for dx in [0.1, 0.2, 0.3] { model.updateZoom(model.movedZoom(added, by: dx)) }
        model.endInteraction()
        #expect(model.store.undoDepth == depth + 1)
        #expect(abs((model.zoomSegments.first { $0.id == added.id }?.start ?? 0) - (added.start + 0.3)) < 1e-9)
        #expect(model.store.undoActionName == "Move Zoom")
        model.undo()
        #expect(model.zoomSegments.first { $0.id == added.id }?.start == added.start)

        // Resize an auto segment: it becomes manual.
        model.beginInteraction("Resize Zoom")
        model.updateZoom(model.resizedZoom(auto, leading: true, by: -0.4))
        model.endInteraction()
        let resized = try #require(model.zoomSegments.first { $0.id == auto.id })
        #expect(resized.isManual)
        #expect(abs(resized.start - (auto.start - 0.4)) < 1e-9 && resized.end == auto.end)

        // Regenerate keeps edited (manual) segments.
        model.regenerateAutoZooms()
        #expect(model.zoomSegments.contains { $0.id == auto.id && $0.isManual })
        #expect(model.zoomSegments.contains { $0.id == added.id })
        model.undo()
        #expect(model.zoomSegments.contains { $0.id == auto.id })

        // Delete key.
        model.selectZoom(added.id)
        #expect(model.deleteSelection())
        #expect(!model.zoomSegments.contains { $0.id == added.id })
        model.undo()
        #expect(model.zoomSegments.contains { $0.id == added.id })

        // Auto off drops auto segments in one step; undo brings them back.
        model.setAutoZoom(false)
        #expect(model.zoomSegments.allSatisfy { $0.isManual })
        model.undo()
        #expect(model.project.zoom.auto)

        // ⌘S writes the package; reading it back gives the same project.
        #expect(await model.save(preview: false))
        #expect(!model.hasUnsavedChanges)
        let reread = try StudioProjectFile.read(from: package).project
        #expect(reread == model.project)
    }

    @MainActor
    @Test func trimAndCutsAreUndoable() async throws {
        let package = try await StudioTestMedia.sample(copy: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let model = try StudioViewModel.load(url: package)
        model.autosaveDelay = .seconds(3600)
        defer { model.tearDown() }

        model.beginInteraction("Trim")
        model.setTrim(start: 0.3)
        model.setTrim(start: 0.6)
        model.endInteraction()
        #expect(model.trimRange.start == 0.6)
        model.rangeSelection = EditTimeRange(start: 1.0, end: 1.5)
        #expect(model.deleteSelection())
        #expect(model.project.edit.cuts == [EditTimeRange(start: 1.0, end: 1.5)])
        #expect(abs(model.timeline.outputDuration - (5 - 0.6 - 0.5)) < 1e-9)
        model.undo()
        #expect(model.project.edit.cuts.isEmpty)
        model.undo()
        #expect(model.project.edit.trim == nil)
    }

    // MARK: Open in Studio

    @Test func openInStudioWrapsClassicMP4() async throws {
        let video = StudioTestMedia.url("classic.mp4")
        try await RenderTestMedia.write(to: video, width: 640, height: 360, fps: 30, seconds: 2, moving: true, audio: true)
        let folder = StudioTestMedia.url("opened", directory: true)
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: folder)
        }
        let package = try await StudioDocumentOpener.makePackage(for: video, scale: 2, folder: folder)
        #expect(package.pathExtension == "hakostudio")
        #expect(package.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        let project = try StudioProjectFile.read(from: package).project
        #expect(project.source.cursorBakedIn)
        #expect(!project.supportsCursorEditing)
        #expect(project.source.media.screen == "classic.mp4")
        #expect(project.source.pixelWidth == 640 && project.source.pixelHeight == 360)
        #expect(project.source.pointWidth == 320)
        #expect(abs(project.source.duration - 2) < 0.05)
        #expect(project.source.audioTracks.count == 1)
        #expect(FileManager.default.fileExists(atPath: StudioProjectFile.mediaURL("classic.mp4", in: package).path))
        #expect(FileManager.default.fileExists(atPath: video.path), "the original stays")

        // Renders: background + content at the canvas size, no cursor overlay.
        let media = StudioMediaContext.load(packageURL: package, project: project)
        let frame = try await StudioExport.frameImage(project: project, media: media, outputTime: 1)
        #expect(CGSize(width: frame.width, height: frame.height) == project.canvasPixelSize)
        let state = StudioRenderAdapter(project: project, media: media).state(sourceTime: 1, outputTime: 1)
        #expect(state.cursor == nil)

        // History placement.
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let placed = StudioDocumentOpener.packageURL(
            for: video, history: .init(rootURL: folder, id: id, date: date)
        )
        #expect(placed.path.hasSuffix("\(id.uuidString).hakostudio"))
    }

    @Test func fixturePackageRendersAndExports() async throws {
        let copy = StudioTestMedia.url("fixture.hakostudio", directory: true)
        try? FileManager.default.removeItem(at: copy)
        try FileManager.default.copyItem(at: StudioTestMedia.fixtureURL, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let contents = try StudioProjectFile.read(from: copy)
        let media = StudioMediaContext.load(packageURL: copy, project: contents.project, assets: contents.assets)
        #expect(media.cursorSprites.count == 1)
        let frame = try await StudioExport.frameImage(project: contents.project, media: media, outputTime: 0.3)
        #expect(frame.height == 720 && frame.width == 1280)
        let out = StudioTestMedia.url("fixture.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        _ = try await StudioExport.export(project: contents.project, media: media, to: out)
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        // Trim 0.1–0.9 minus the 0.4–0.5 cut = 0.7 s.
        #expect(abs(duration - 0.7) <= 1.0 / 30 + 1e-3)
    }

    // MARK: DEBUG URLs

    @Test func debugCommandsParse() throws {
        func items(_ pairs: [String: String]) -> [URLQueryItem] { pairs.map { URLQueryItem(name: $0.key, value: $0.value) } }
        let frame = try StudioDebug.Command(host: "debug-render-studio-frame", queryItems: items(["project": "/tmp/a.hakostudio", "time": "3.5", "out": "/tmp/f.png"]))
        #expect(frame == .renderFrame(project: URL(fileURLWithPath: "/tmp/a.hakostudio"), time: 3.5, out: URL(fileURLWithPath: "/tmp/f.png"), height: nil))
        let export = try StudioDebug.Command(host: "debug-export-studio", queryItems: items(["project": "/tmp/a.hakostudio", "out": "/tmp/o.gif", "format": "gif"]))
        #expect(export == .export(project: URL(fileURLWithPath: "/tmp/a.hakostudio"), out: URL(fileURLWithPath: "/tmp/o.gif"), format: .gif))
        let snapshot = try StudioDebug.Command(host: "debug-studio-snapshot", queryItems: items(["project": "/tmp/a.hakostudio", "out": "/tmp/s.png", "close": "0"]))
        #expect(snapshot == .snapshot(project: URL(fileURLWithPath: "/tmp/a.hakostudio"), out: URL(fileURLWithPath: "/tmp/s.png"), close: false))
        let zoom = try StudioDebug.Command(host: "debug-studio-zoom", queryItems: items(["project": "/tmp/a.hakostudio", "add": "1,2.5,2,0.25,0.75"]))
        guard case let .zoom(project, segment, out)? = zoom else { Issue.record("not a zoom command"); return }
        #expect(project == out)
        #expect(segment.start == 1 && segment.end == 2.5 && segment.scale == 2 && segment.focus == .fixed(x: 0.25, y: 0.75) && segment.isManual)
        #expect(throws: StudioDebug.ParseError.missing("time")) {
            _ = try StudioDebug.Command(host: "debug-render-studio-frame", queryItems: items(["project": "/a", "out": "/b"]))
        }
        let other = try StudioDebug.Command(host: "debug-other", queryItems: [])
        #expect(other == nil)
    }

    @Test func debugZoomAddsSegmentToNewPackage() async throws {
        let package = try await StudioTestMedia.sample()
        let out = StudioTestMedia.url("zoomed.hakostudio", directory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let segment = ZoomSegment(start: 0.5, end: 1.5, scale: 3, focus: .fixed(x: 0.75, y: 0.75), isManual: true)
        _ = try StudioDebug.addZoom(project: package, segment: segment, out: out)
        let project = try StudioProjectFile.read(from: out).project
        #expect(project.zoom.segments.contains { $0.id == segment.id && $0.isManual })
        // Zoomed 3× on the bottom-right quadrant at t = 1.
        let frame = try await StudioDebug.renderFrame(project: out, time: 1.0, out: StudioTestMedia.url("zoomed.png"))
        try? FileManager.default.removeItem(at: StudioTestMedia.url("zoomed.png"))
        let center = try #require(StudioTestMedia.pixel(frame, x: frame.width / 2 - 200, y: frame.height / 2 - 200))
        #expect(StudioTestMedia.close(center, StudioTestMedia.yellow, tolerance: 20))
    }

    // MARK: Snapshot (opt-in: opens a window)

    /// `HAKO_STUDIO_SNAPSHOT=<dir>` (xcodebuild: `TEST_RUNNER_HAKO_STUDIO_SNAPSHOT`)
    /// writes `studio-snapshot.png` (editor window) there for a visual check.
    nonisolated static let snapshotDirectory = ProcessInfo.processInfo.environment["HAKO_STUDIO_SNAPSHOT"]

    @MainActor
    @Test(.enabled(if: snapshotDirectory != nil, "opt-in (HAKO_STUDIO_SNAPSHOT=<dir>) opens the editor window"))
    func editorWindowSnapshot() async throws {
        let package = try await StudioTestMedia.sample(copy: true)
        defer { try? FileManager.default.removeItem(at: package) }
        let out = URL(fileURLWithPath: try #require(Self.snapshotDirectory)).appending(path: "studio-snapshot.png")
        let size = try await StudioDebug.snapshot(project: package, out: out, close: true)
        StudioTestMedia.log("snapshot \(Int(size.width))x\(Int(size.height)) -> \(out.path)")
        #expect(size.width > 0)
    }

    // MARK: Performance (logged)

    @Test func performanceTenSecond1080p() async throws {
        let package = StudioTestMedia.url("perf.hakostudio", directory: true)
        defer { try? FileManager.default.removeItem(at: package) }
        var spec = StudioSampleProject.Spec()
        spec.seconds = 10
        spec.fps = 60
        spec.clicks = [.init(time: 2, x: 0.25, y: 0.25), .init(time: 6, x: 0.75, y: 0.7)]
        let project = try await StudioSampleProject.make(at: package, spec: spec)
        let media = StudioMediaContext.load(packageURL: package, project: project)

        // Preview path: 1080p canvas, preview blur, all frames through the compositor.
        let build = try await StudioExport.build(project: project, media: media, purpose: .preview(outputHeight: 1080, fps: 60), includeAudio: false)
        let preview = try StudioTestMedia.readAllFrames(build.composition)
        let previewFPS = Double(preview.frames) / preview.seconds
        StudioTestMedia.log(String(format: "perf preview 1080p60: %d frames in %.2f s = %.1f fps (%.2f ms/frame)",
                                   preview.frames, preview.seconds, previewFPS, preview.seconds / Double(max(preview.frames, 1)) * 1000))

        // Export: 10 s 1080p60 H.264 with motion blur.
        let out = StudioTestMedia.url("perf.mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let started = ContinuousClock.now
        _ = try await StudioExport.export(project: project, media: media, to: out)
        let elapsed = ContinuousClock.now - started
        let duration = try await AVURLAsset(url: out).load(.duration).seconds
        StudioTestMedia.log("perf export 10 s 1080p60 mp4: \(elapsed) (\(String(format: "%.3f", duration)) s output)")
        #expect(abs(duration - 10) <= 1.0 / 60 + 1e-3)
        #expect(preview.frames >= 590)
    }
}

// MARK: - Media helpers

nonisolated enum StudioTestMedia {
    static let directory = FileManager.default.temporaryDirectory.appending(path: "hako-studio-tests-\(ProcessInfo.processInfo.processIdentifier)")
    private static let cache = SampleCache()

    static let red = (230, 40, 40)
    static let green = (40, 200, 60)
    static let blue = (40, 80, 230)
    static let yellow = (240, 210, 40)

    /// `Packages/HakoKit/Tests/HakoKitTests/Fixtures/v1-basic.hakostudio` (read only).
    static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Packages/HakoKit/Tests/HakoKitTests/Fixtures/v1-basic.hakostudio")
    }

    static func url(_ name: String, directory isDirectory: Bool = false) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: name, directoryHint: isDirectory ? .isDirectory : .notDirectory)
    }

    /// The shared 5 s 1920×1080 30 fps sample (don't modify), or a private copy.
    static func sample(copy: Bool = false) async throws -> URL {
        let shared = try await cache.url()
        guard copy else { return shared }
        let target = url("sample-\(UUID().uuidString).hakostudio", directory: true)
        try FileManager.default.copyItem(at: shared, to: target)
        return target
    }

    private actor SampleCache {
        private var task: Task<URL, any Error>?

        func url() async throws -> URL {
            if let task { return try await task.value }
            let task = Task {
                let url = StudioTestMedia.url("sample.hakostudio", directory: true)
                var spec = StudioSampleProject.Spec()
                spec.fps = 30
                _ = try await StudioSampleProject.make(at: url, spec: spec)
                return url
            }
            self.task = task
            return try await task.value
        }
    }

    static func log(_ message: String) {
        RenderTestMedia.log("[studio] \(message)")
    }

    static func pixel(_ image: CGImage, x: Int, y: Int) -> (Int, Int, Int)? {
        RenderTestMedia.pixel(image, x: x, y: y).map { (Int($0.r), Int($0.g), Int($0.b)) }
    }

    static func close(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int) -> Bool {
        abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
    }

    /// Pixels on `row` that mix the red and green quadrants.
    static func mixedRedGreenCount(_ image: CGImage, row: Int) -> Int {
        guard let buffer = RGBAPixelBuffer(cgImage: image) else { return 0 }
        var count = 0
        for x in 0..<buffer.width {
            let i = (row * buffer.width + x) * 4
            let r = Int(buffer.pixels[i]), g = Int(buffer.pixels[i + 1]), b = Int(buffer.pixels[i + 2])
            if r > 70, g > 70, r < 215, g < 190, b < 90 { count += 1 }
        }
        return count
    }

    /// The sample's quadrant frame as a Core Image source (y up).
    static func quadrantImage(width: Int, height: Int) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let halfW = CGFloat(width / 2), halfH = CGFloat(height / 2)
        let rects = [
            CGRect(x: 0, y: halfH, width: halfW, height: halfH), CGRect(x: halfW, y: halfH, width: halfW, height: halfH),
            CGRect(x: 0, y: 0, width: halfW, height: halfH), CGRect(x: halfW, y: 0, width: halfW, height: halfH),
        ]
        for (rect, c) in zip(rects, StudioSampleProject.quadrantColors) {
            context.setFillColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
            context.fill(rect)
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    /// Reads every composed frame (the player's per-frame work) and times it.
    static func readAllFrames(_ composition: RenderComposition) throws -> (frames: Int, seconds: Double) {
        let reader = try AVAssetReader(asset: composition.composition)
        let output = AVAssetReaderVideoCompositionOutput(videoTracks: [composition.videoTrack!], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        output.videoComposition = composition.videoComposition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        let started = ContinuousClock.now
        reader.startReading()
        var frames = 0
        while output.copyNextSampleBuffer() != nil { frames += 1 }
        let elapsed = (ContinuousClock.now - started).components
        return (frames, Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
    }
}
