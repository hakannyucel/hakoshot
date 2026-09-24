import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

enum StudioTestSupport {
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("StudioTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // Studio
        .deletingLastPathComponent() // Recording
        .deletingLastPathComponent() // HakoKitTests
        .appendingPathComponent("Fixtures", isDirectory: true)

    static let v1Fixture = fixturesDirectory.appendingPathComponent("v1-basic.hakostudio", isDirectory: true)

    /// A fake RawRecording session folder: stand-in `screen.mov` bytes,
    /// `events.json`, `cursor.bin`, `cursors/<hash>.png`, plus an unrelated
    /// `session.json` that must not be taken.
    static func makeSessionFolder(in root: URL, camera: Bool = false, events: Bool = true) throws -> URL {
        let folder = root.appendingPathComponent("session", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.appendingPathComponent("cursors"), withIntermediateDirectories: true)
        try Data("fake video".utf8).write(to: folder.appendingPathComponent("screen.mov"))
        if camera { try Data("fake camera".utf8).write(to: folder.appendingPathComponent("camera.mov")) }
        if events { try V1StudioFixture.metadata().jsonData().write(to: folder.appendingPathComponent("events.json")) }
        try CursorTrackCodec.encode(V1StudioFixture.samples()).write(to: folder.appendingPathComponent("cursor.bin"))
        try Data("png".utf8).write(to: folder.appendingPathComponent("cursors/fixturearrow.png"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("session.json"))
        return folder
    }

    static func solidImage(width: Int, height: Int, gray: Double = 0.5) -> CGImage? {
        guard let ctx = RenderSupport.makeBitmapContext(width: width, height: height) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// What the committed `Fixtures/v1-basic.hakostudio` contains. It was written
/// once by v1's `StudioProjectFile.write(project(), preview:, to:, mediaSource:)`
/// with a synthetic 1 s 128×72 H.264 `screen.mov` (four color quadrants, a
/// moving black square), `events.json` = `metadata()`, `cursor.bin` =
/// `samples()` and an 8×8 `cursors/fixturearrow.png`. **Never regenerate
/// it**: it proves v1 packages keep opening. After a format change, add a
/// new fixture (v2-…) instead.
enum V1StudioFixture {
    static let createdAt = Date(timeIntervalSince1970: 1_790_000_000)
    static let segmentID = UUID(uuidString: "5E6A0000-0000-4000-8000-000000000001")!

    static func metadata() -> RecordingMetadata {
        RecordingMetadata(
            hostTimeOrigin: 1000,
            geometry: RecordingGeometryInfo(rect: CGRect(x: 0, y: 0, width: 64, height: 36), displayID: 1,
                                            scale: 2, pixelWidth: 128, pixelHeight: 72),
            clicks: [
                RecordingClickEvent(time: 0.5, x: 16, y: 9, button: .left, isDown: true),
                RecordingClickEvent(time: 0.55, x: 16, y: 9, button: .left, isDown: false),
            ],
            cursorShapes: [RecordingCursorShape(hash: "fixturearrow", hotSpotX: 1, hotSpotY: 1, width: 8, height: 8)],
            cursorBakedIn: false
        )
    }

    /// 31 samples at 30 Hz moving right 2 pt per frame.
    static func samples() -> [CursorSample] {
        (0...30).map { (i: Int) -> CursorSample in
            let flags: CursorSampleFlags = (15..<17).contains(i) ? .leftDown : []
            return CursorSample(time: Double(i) / 30, x: Float(2 * i), y: 9, shapeIndex: 0, flags: flags)
        }
    }

    static func project() -> StudioProject {
        let source = StudioSource(pixelWidth: 128, pixelHeight: 72, pointWidth: 64, pointHeight: 36, fps: 30,
                                  duration: 1, cursorBakedIn: false, audioTracks: [])
        var background = StudioCanvas.defaultBackground
        background.fill = .solid(RGBAColor(red: 0.2, green: 0.4, blue: 0.6))
        background.padding = 32
        background.cornerRadius = 8
        return StudioProject(
            source: source,
            createdAt: createdAt,
            edit: StudioEdit(trim: EditTimeRange(start: 0.1, end: 0.9), cuts: [EditTimeRange(start: 0.4, end: 0.5)]),
            canvas: StudioCanvas(aspectRatio: .sixteenNine, outputHeight: 720, background: background),
            cursor: StudioCursorSettings(scale: 2, smoothing: 0.5, hideWhenIdle: true),
            zoom: StudioZoomSettings(auto: true, defaultScale: 2, speed: .normal, segments: [
                ZoomSegment(id: segmentID, start: 0.2, end: 0.7, scale: 2.5, focus: .fixed(x: 0.25, y: 0.25), isManual: true),
            ]),
            motionBlur: StudioMotionBlur(enabled: true, intensity: 0.4),
            export: StudioExportSettings(format: .mp4, fps: 30, quality: .high, codec: .h264)
        )
    }
}

@Suite("StudioProjectFile")
struct StudioProjectFileTests {
    @Test func packageRoundTripThroughTempDirectory() throws {
        let root = try StudioTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try StudioTestSupport.makeSessionFolder(in: root)
        let url = root.appendingPathComponent("Demo.hakostudio")

        let created = try StudioProjectFile.create(
            from: folder, source: StudioSource(pixelWidth: 128, pixelHeight: 72, fps: 30, duration: 1),
            at: url, transfer: .copy, createdAt: V1StudioFixture.createdAt)
        #expect(created.source.cursorBakedIn == false) // from events.json
        #expect(created.source.pointWidth == 64)

        var edited = created
        edited.canvas.aspectRatio = .nineSixteen
        edited.edit.trim = EditTimeRange(start: 0.2, end: 0.8)
        let bg = try #require(StudioTestSupport.solidImage(width: 20, height: 10))
        let asset = AssetID(rawValue: "BG")
        edited.canvas.background.fill = .image(asset)
        let preview = try #require(StudioTestSupport.solidImage(width: 2048, height: 1024))
        try StudioProjectFile.write(edited, assets: [asset: bg], preview: preview, to: url)

        let read = try StudioProjectFile.read(from: url)
        #expect(read.project == edited)
        #expect(read.assets[asset]?.width == 20)
        let previewImage = try #require(StudioProjectFile.readPreview(from: url))
        #expect(previewImage.width == 1024 && previewImage.height == 512)
        // Media survived the save untouched.
        let media = StudioProjectFile.mediaURLs(for: read.project, in: url)
        #expect(try Data(contentsOf: media.screen) == Data("fake video".utf8))
        #expect(StudioProjectFile.readCursorTrack(for: read.project, in: url) == V1StudioFixture.samples())
        #expect(StudioProjectFile.readMetadata(for: read.project, in: url) == V1StudioFixture.metadata())

        // Second save without assets / preview keeps both from disk.
        edited.cursor.scale = 3
        try StudioProjectFile.write(edited, to: url)
        let again = try StudioProjectFile.read(from: url)
        #expect(again.project.cursor.scale == 3)
        #expect(again.assets[asset] != nil)
        #expect(StudioProjectFile.readPreview(from: url) != nil)
    }

    @Test func createMovesFilesAndDropsMissingOptionals() throws {
        let root = try StudioTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try StudioTestSupport.makeSessionFolder(in: root, camera: true)
        let url = root.appendingPathComponent("Moved.hakostudio")
        var source = StudioSource(pixelWidth: 128, pixelHeight: 72, duration: 1)
        source.media.camera = StudioMediaFiles.defaultCamera

        let project = try StudioProjectFile.create(from: folder, source: source, at: url)
        #expect(project.source.hasCamera)
        #expect(project.source.media.cursorsDirectory == "cursors")
        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: folder.appendingPathComponent("screen.mov").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("session.json").path))
        for name in ["screen.mov", "camera.mov", "events.json", "cursor.bin", "cursors/fixturearrow.png"] {
            #expect(fm.fileExists(atPath: url.appendingPathComponent("media/\(name)").path), "\(name)")
        }
        #expect(try StudioProjectFile.read(from: url).project == project)

        // No camera in the folder → dropped from the project.
        let root2 = try StudioTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root2) }
        let plain = try StudioTestSupport.makeSessionFolder(in: root2)
        let p2 = try StudioProjectFile.create(from: plain, source: source,
                                              at: root2.appendingPathComponent("P.hakostudio"), transfer: .copy)
        #expect(p2.source.media.camera == nil)
    }

    @Test func createWithoutEventsFileWritesMetadataOrBakesCursor() throws {
        let root = try StudioTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = StudioSource(pixelWidth: 128, pixelHeight: 72, duration: 1)

        // Metadata passed in → written, cursor editable.
        let a = try StudioTestSupport.makeSessionFolder(in: root.appendingPathComponent("a"), events: false)
        let urlA = root.appendingPathComponent("A.hakostudio")
        let pa = try StudioProjectFile.create(from: a, metadata: V1StudioFixture.metadata(), source: source, at: urlA)
        #expect(pa.source.cursorBakedIn == false)
        #expect(StudioProjectFile.readMetadata(for: pa, in: urlA) == V1StudioFixture.metadata())

        // Nothing → classic recording, cursor baked in.
        let b = try StudioTestSupport.makeSessionFolder(in: root.appendingPathComponent("b"), events: false)
        let pb = try StudioProjectFile.create(from: b, source: source, at: root.appendingPathComponent("B.hakostudio"))
        #expect(pb.source.cursorBakedIn)
        #expect(pb.source.media.events == nil)
        #expect(!pb.supportsCursorEditing)
    }

    @Test func createFailureRestoresMovedFiles() throws {
        let root = try StudioTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try StudioTestSupport.makeSessionFolder(in: root)
        var source = StudioSource(pixelWidth: 128, pixelHeight: 72, duration: 1)

        // Missing screen: fails before anything moves.
        source.media.screen = "missing.mov"
        #expect(throws: StudioProjectFileError.missingMedia("missing.mov")) {
            _ = try StudioProjectFile.create(from: folder, source: source, at: root.appendingPathComponent("X.hakostudio"))
        }

        // A nested name has no parent folder in `media/`, so its move fails
        // after screen.mov and cursor.bin were moved: both must come back.
        source.media.screen = "screen.mov"
        source.media.cursorsDirectory = "sub/cursors"
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub/cursors"), withIntermediateDirectories: true)
        let target = root.appendingPathComponent("Y.hakostudio")
        #expect(throws: StudioProjectFileError.self) {
            _ = try StudioProjectFile.create(from: folder, source: source, at: target)
        }
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("screen.mov").path))
        #expect(fm.fileExists(atPath: folder.appendingPathComponent("cursor.bin").path))
        #expect(!fm.fileExists(atPath: target.path))
    }

    @Test func fileWrapperRoundTripReusesMedia() throws {
        let project = V1StudioFixture.project()
        let screen = FileWrapper(regularFileWithContents: Data("v".utf8))
        let media = FileWrapper(directoryWithFileWrappers: ["screen.mov": screen])
        let preview = try #require(StudioTestSupport.solidImage(width: 10, height: 10))
        let wrapper = try StudioProjectFile.fileWrapper(for: project, media: media, preview: preview)
        #expect(wrapper.fileWrappers?[StudioProjectFile.previewFileName] != nil)
        #expect(try StudioProjectFile.read(from: wrapper).project == project)

        // Resave from the previous wrapper: media and preview carried over.
        var changed = project
        changed.motionBlur.enabled = false
        let second = try StudioProjectFile.fileWrapper(for: changed, reusing: wrapper)
        #expect(second.fileWrappers?["media"]?.fileWrappers?["screen.mov"] != nil)
        #expect(second.fileWrappers?[StudioProjectFile.previewFileName] != nil)
        #expect(try StudioProjectFile.read(from: second).project == changed)

        #expect(throws: StudioProjectFileError.missingMedia("media")) {
            _ = try StudioProjectFile.fileWrapper(for: project)
        }
    }

    @Test func rejectsNewerVersionAndBrokenPackages() throws {
        let root = try StudioTestSupport.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try StudioTestSupport.makeSessionFolder(in: root)
        let url = root.appendingPathComponent("N.hakostudio")
        _ = try StudioProjectFile.create(from: folder, source: StudioSource(pixelWidth: 128, pixelHeight: 72, duration: 1),
                                         at: url, transfer: .copy)
        let jsonURL = url.appendingPathComponent(StudioProjectFile.projectFileName)
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any])
        object["formatVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: jsonURL)
        #expect(throws: StudioProjectFileError.unsupportedFormatVersion(2)) {
            _ = try StudioProjectFile.read(from: url)
        }

        try Data("not json".utf8).write(to: jsonURL)
        #expect(throws: StudioProjectFileError.corruptProjectJSON("project.json is not a versioned JSON object")) {
            _ = try StudioProjectFile.read(from: url)
        }

        try FileManager.default.removeItem(at: jsonURL)
        #expect(throws: StudioProjectFileError.missingProjectJSON) { _ = try StudioProjectFile.read(from: url) }
        #expect(throws: StudioProjectFileError.notAPackage) {
            _ = try StudioProjectFile.read(from: root.appendingPathComponent("nope.hakostudio"))
        }
    }

    @Test func migrationHookRunsSteps() throws {
        let v0 = Data(#"{"formatVersion":0,"legacy":true}"#.utf8)
        #expect(throws: Migration.Error.noMigrationPath(from: 0)) { _ = try StudioMigration.upgrade(v0) }
        let step = Migration.Step(from: 0) { json in
            json["source"] = .object(["pixelWidth": .number(10), "pixelHeight": .number(10), "duration": .number(1)])
        }
        let upgraded = try StudioMigration.upgrade(v0, to: 1, steps: [step])
        let project = try StudioProject(jsonData: upgraded)
        #expect(project.source.pixelWidth == 10)
        #expect(throws: Migration.Error.newerVersion(5)) {
            _ = try StudioMigration.upgrade(Data(#"{"formatVersion":5}"#.utf8))
        }
    }

    // MARK: v1 fixture

    @Test func v1FixtureDecodes() throws {
        let url = StudioTestSupport.v1Fixture
        let contents = try StudioProjectFile.read(from: url)
        #expect(contents.project == V1StudioFixture.project())
        #expect(StudioProjectFile.readMetadata(for: contents.project, in: url) == V1StudioFixture.metadata())
        #expect(StudioProjectFile.readCursorTrack(for: contents.project, in: url) == V1StudioFixture.samples())
        let media = StudioProjectFile.mediaURLs(for: contents.project, in: url)
        let screenSize = try FileManager.default.attributesOfItem(atPath: media.screen.path)[.size] as? Int ?? 0
        #expect(screenSize > 1000)
        let cursors = try #require(media.cursorsDirectory)
        #expect(FileManager.default.fileExists(atPath: cursors.appendingPathComponent("fixturearrow.png").path))
        #expect(StudioProjectFile.readPreview(from: url) != nil)

        // Also decodes through the FileWrapper path.
        let wrapper = try FileWrapper(url: url, options: [])
        #expect(try StudioProjectFile.read(from: wrapper).project == V1StudioFixture.project())
    }
}
