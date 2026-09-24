import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("ProjectFile")
struct ProjectFileTests {
    // MARK: Helpers

    /// A unique scratch directory, removed by the caller's `defer`.
    static func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProjectFileTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// `Tests/HakoKitTests/Fixtures`, located from this source file (the test
    /// target declares no resources).
    static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures", isDirectory: true)

    static let v1Fixture = fixturesDirectory.appendingPathComponent("v1-basic.hakoshot", isDirectory: true)

    /// Full document (every annotation kind) with small real images.
    static func fullDocumentAndAssets() throws -> (ProjectDocument, [AssetID: CGImage]) {
        var doc = AnnotationFixtures.fullDocument()
        doc.background = nil // renderer draws no background yet; keep preview size = output size
        let base = try #require(RenderFixtures.pattern(width: 2000, height: 1200))
        let extra = try #require(RenderFixtures.solid(RGBAColor(hex: "#34C75980") ?? .black, width: 40, height: 30))
        return (doc, [AnnotationFixtures.baseAsset: base, AnnotationFixtures.extraAsset: extra])
    }

    static func pixelsEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard let pa = PixelBuffer(a), let pb = PixelBuffer(b) else { return false }
        return pa.width == pb.width && pa.height == pb.height && pa.bytes == pb.bytes
    }

    // MARK: Round trip

    @Test func roundTripsEveryAnnotationKindAndAssetsPixelEqual() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, assets) = try Self.fullDocumentAndAssets()
        #expect(Set(doc.annotations.map(\.kind.tag)) == Set(Annotation.KindTag.allCases))

        let url = dir.appendingPathComponent("Shot.hakoshot")
        try ProjectFile.write(doc, assets: assets, to: url)
        let contents = try ProjectFile.read(from: url)

        #expect(contents.document == doc)
        #expect(Set(contents.assets.keys) == doc.referencedAssets)
        for (id, image) in assets {
            let loaded = try #require(contents.assets[id])
            #expect(Self.pixelsEqual(image, loaded), "asset \(id.rawValue) changed")
        }
    }

    @Test func bundleLayoutAndStableJSON() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, assets) = try Self.fullDocumentAndAssets()
        // An unreferenced image is not written.
        var extraAssets = assets
        let unused = try #require(RenderFixtures.solid(.white, width: 2, height: 2))
        extraAssets[AssetID(rawValue: "UNUSED")] = unused
        let url = dir.appendingPathComponent("Shot.hakoshot")
        try ProjectFile.write(doc, assets: extraAssets, to: url)

        let fm = FileManager.default
        #expect(Set(try fm.contentsOfDirectory(atPath: url.path)) == ["project.json", "assets", "preview.png"])
        let assetFiles = Set(try fm.contentsOfDirectory(atPath: url.appendingPathComponent("assets").path))
        #expect(assetFiles == Set(doc.referencedAssets.map { "\($0.rawValue).png" }))

        let json = try Data(contentsOf: url.appendingPathComponent("project.json"))
        #expect(json == (try doc.jsonData()))
        #expect(String(decoding: json, as: UTF8.self).contains("\n  \"annotations\""))
    }

    @Test func fileWrapperRoundTrip() throws {
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let wrapper = try ProjectFile.fileWrapper(for: doc, assets: assets, includePreview: false)
        #expect(wrapper.fileWrappers?["preview.png"] == nil)
        let contents = try ProjectFile.read(from: wrapper)
        #expect(contents.document == doc)
        #expect(contents.assets.count == 2)
    }

    @Test func reusesExistingAssetFilesWhenImagesAreNotInMemory() throws {
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let first = try ProjectFile.fileWrapper(for: doc, assets: assets, includePreview: false)
        var edited = doc
        edited.annotations.removeFirst()
        // Only the document changed; no images passed in.
        let second = try ProjectFile.fileWrapper(for: edited, assets: [:], reusing: first)
        let contents = try ProjectFile.read(from: second)
        #expect(contents.document == edited)
        for (id, image) in assets {
            #expect(Self.pixelsEqual(image, try #require(contents.assets[id])))
        }
        #expect(second.fileWrappers?["preview.png"] != nil)
    }

    @Test func overwritesExistingPackageAtomically() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let url = dir.appendingPathComponent("Shot.hakoshot")
        try ProjectFile.write(doc, assets: assets, to: url)

        var edited = doc
        edited.annotations = [AnnotationFixtures.rect(1, 2, 3, 4)]
        edited.layers = [ImageLayer(assetID: AnnotationFixtures.baseAsset, frame: doc.canvas.rect)]
        // Base image not in memory: taken from the file on disk.
        try ProjectFile.write(edited, assets: [:], to: url)

        let contents = try ProjectFile.read(from: url)
        #expect(contents.document == edited)
        #expect(contents.assets.keys.sorted { $0.rawValue < $1.rawValue } == [AnnotationFixtures.baseAsset])
        let assetFiles = try FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("assets").path)
        #expect(assetFiles == ["\(AnnotationFixtures.baseAsset.rawValue).png"])
        // No leftovers from staging next to the package.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["Shot.hakoshot"])
    }

    // MARK: Preview

    @Test func previewExistsWithExpectedSize() throws {
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let url = dir.appendingPathComponent("Shot.hakoshot")
        try ProjectFile.write(doc, assets: assets, to: url)

        // Crop 1800×1000, rotated a quarter turn → 1000×1800 → fits 1024: 569×1024.
        let preview = try #require(ProjectFile.readPreview(from: url))
        #expect(preview.width == 569)
        #expect(preview.height == 1024)
        #expect(ProjectFile.previewSize(for: doc) == CGSize(width: 569, height: 1024))
    }

    @Test func smallPreviewIsNotEnlarged() throws {
        let doc = RenderFixtures.document(width: 300, height: 200)
        let base = try #require(RenderFixtures.solid(.annotationRed, width: 300, height: 200))
        let preview = try #require(ProjectFile.previewImage(for: doc, assets: [RenderFixtures.base: base]))
        #expect(preview.width == 300)
        #expect(preview.height == 200)
        let pixels = try #require(PixelBuffer(preview))
        #expect(pixels.pixel(150, 100).isClose(to: RGBA(.annotationRed)))
    }

    // MARK: Compatibility fixture

    @Test func readsCommittedV1Fixture() throws {
        let contents = try ProjectFile.read(from: Self.v1Fixture)
        let doc = contents.document
        #expect(doc.formatVersion == 1)
        #expect(doc.canvas == CanvasInfo(width: 64, height: 48, scale: 2))
        #expect(doc.createdAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(doc.source?.mode == "area")
        #expect(doc.layers.count == 1)
        #expect(doc.annotations.map(\.kind.tag) == [.rectangle, .arrow, .text, .counter, .redaction])
        if case .text(let text) = doc.annotations[2].kind {
            #expect(text.text == "Hi")
        } else {
            Issue.record("third annotation is not text")
        }

        // After migration to the current version, the model must still equal
        // what v1 wrote.
        #expect(doc == V1Fixture.document())

        let base = try #require(contents.assets[V1Fixture.asset])
        #expect(Self.pixelsEqual(base, try #require(V1Fixture.image())))
        let pixels = try #require(PixelBuffer(base))
        #expect(pixels.pixel(8, 8).isClose(to: RGBA(r: 255, g: 0, b: 0), tolerance: 1))
        #expect(pixels.pixel(56, 40).isClose(to: RGBA(r: 0, g: 0, b: 255), tolerance: 1))

        let preview = try #require(ProjectFile.readPreview(from: Self.v1Fixture))
        #expect(preview.width == 64 && preview.height == 48)
    }

    // MARK: Errors

    @Test func refusesNewerFormatVersion() throws {
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let wrapper = try ProjectFile.fileWrapper(for: doc, assets: assets, includePreview: false)
        var object = try #require(try JSONSerialization.jsonObject(with: doc.jsonData()) as? [String: Any])
        object["formatVersion"] = 7
        let json = try JSONSerialization.data(withJSONObject: object)
        replace("project.json", with: json, in: wrapper)
        #expect(throws: ProjectFileError.unsupportedFormatVersion(7)) {
            try ProjectFile.read(from: wrapper)
        }
    }

    @Test func missingAssetOnRead() throws {
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let wrapper = try ProjectFile.fileWrapper(for: doc, assets: assets, includePreview: false)
        let assetsDir = try #require(wrapper.fileWrappers?["assets"])
        let file = try #require(assetsDir.fileWrappers?["\(AnnotationFixtures.extraAsset.rawValue).png"])
        assetsDir.removeFileWrapper(file)
        #expect(throws: ProjectFileError.missingAsset(AnnotationFixtures.extraAsset)) {
            try ProjectFile.read(from: wrapper)
        }
    }

    @Test func missingAssetOnWrite() throws {
        let (doc, assets) = try Self.fullDocumentAndAssets()
        var partial = assets
        partial[AnnotationFixtures.extraAsset] = nil
        #expect(throws: ProjectFileError.missingAsset(AnnotationFixtures.extraAsset)) {
            try ProjectFile.fileWrapper(for: doc, assets: partial)
        }
    }

    @Test func corruptAsset() throws {
        let (doc, assets) = try Self.fullDocumentAndAssets()
        let wrapper = try ProjectFile.fileWrapper(for: doc, assets: assets, includePreview: false)
        let assetsDir = try #require(wrapper.fileWrappers?["assets"])
        replace("\(AnnotationFixtures.baseAsset.rawValue).png", with: Data("not a png".utf8), in: assetsDir)
        #expect(throws: ProjectFileError.corruptAsset(AnnotationFixtures.baseAsset)) {
            try ProjectFile.read(from: wrapper)
        }
    }

    @Test(arguments: [
        "{ this is not json",
        "[1, 2, 3]",
        #"{"canvas": {"width": 1, "height": 1, "scale": 1}, "layers": []}"#,
    ])
    func corruptJSONIsRejected(json: String) throws {
        let wrapper = FileWrapper(directoryWithFileWrappers: [:])
        replace("project.json", with: Data(json.utf8), in: wrapper)
        do {
            _ = try ProjectFile.read(from: wrapper)
            Issue.record("expected corruptProjectJSON")
        } catch {
            guard case .corruptProjectJSON = error else {
                Issue.record("unexpected error \(error)")
                return
            }
        }
    }

    @Test func schemaMismatchIsCorruptJSON() throws {
        // Valid version, but `layers` has the wrong type.
        let json = #"{"formatVersion": 1, "canvas": {"width": 1, "height": 1, "scale": 1}, "layers": 5}"#
        let wrapper = FileWrapper(directoryWithFileWrappers: [:])
        replace("project.json", with: Data(json.utf8), in: wrapper)
        #expect {
            try ProjectFile.read(from: wrapper)
        } throws: { error in
            if case ProjectFileError.corruptProjectJSON = error { return true }
            return false
        }
    }

    @Test func missingProjectJSONAndNonPackage() throws {
        #expect(throws: ProjectFileError.missingProjectJSON) {
            try ProjectFile.read(from: FileWrapper(directoryWithFileWrappers: [:]))
        }
        #expect(throws: ProjectFileError.notAPackage) {
            try ProjectFile.read(from: FileWrapper(regularFileWithContents: Data()))
        }
        let dir = try Self.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ProjectFileError.notAPackage) {
            try ProjectFile.read(from: dir.appendingPathComponent("Nope.hakoshot"))
        }
    }

    private func replace(_ name: String, with data: Data, in directory: FileWrapper) {
        if let old = directory.fileWrappers?[name] { directory.removeFileWrapper(old) }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        directory.addFileWrapper(file)
    }
}

// MARK: - Migration

@Suite("Migration")
struct MigrationTests {
    @Test func currentVersionPassesThroughUnchanged() throws {
        let data = try AnnotationFixtures.fullDocument().jsonData()
        #expect(try Migration.upgrade(data) == data)
        #expect(try Migration.formatVersion(of: data) == ProjectDocument.currentFormatVersion)
    }

    @Test func appliesStepsInOrderAndSetsVersion() throws {
        // Pretend v1 → v3 with a rename (v1→v2) and a new field (v2→v3).
        let steps = [
            Migration.Step(from: 2) { json in json["added"] = .bool(true) },
            Migration.Step(from: 1) { json in
                json["renamed"] = json.removeValue(forKey: "old")
            },
        ]
        let input = Data(#"{"formatVersion": 1, "old": "x", "keep": [1, 2]}"#.utf8)
        let output = try Migration.upgrade(input, to: 3, steps: steps)
        let object = try JSONDecoder().decode([String: JSONValue].self, from: output)
        #expect(object == [
            "formatVersion": .number(3), "renamed": .string("x"), "added": .bool(true),
            "keep": .array([.number(1), .number(2)]),
        ])
        #expect(try Migration.formatVersion(of: output) == 3)
    }

    @Test func errors() {
        #expect(throws: Migration.Error.newerVersion(4)) {
            try Migration.upgrade(Data(#"{"formatVersion": 4}"#.utf8), to: 3, steps: [])
        }
        #expect(throws: Migration.Error.noMigrationPath(from: 0)) {
            try Migration.upgrade(Data(#"{"formatVersion": 0}"#.utf8), to: 1, steps: [])
        }
        #expect(throws: Migration.Error.unreadable) {
            try Migration.upgrade(Data(#"{"formatVersion": "one"}"#.utf8))
        }
        struct Boom: Error {}
        #expect(throws: Migration.Error.stepFailed(from: 1, reason: "Boom()")) {
            try Migration.upgrade(Data(#"{"formatVersion": 1}"#.utf8), to: 2,
                                  steps: [Migration.Step(from: 1) { _ in throw Boom() }])
        }
    }

    @Test func olderFileWithoutMigrationPathFailsToOpen() {
        let json = #"{"formatVersion": 0, "canvas": {"width": 1, "height": 1, "scale": 1}, "layers": []}"#
        #expect {
            try ProjectFile.decodeDocument(Data(json.utf8))
        } throws: { error in
            if case ProjectFileError.migrationFailed = error { return true }
            return false
        }
    }
}

// MARK: - v1 fixture

/// What the committed `Fixtures/v1-basic.hakoshot` contains. The bundle was
/// written once by v1's `ProjectFile.write(document(), assets: [asset: image()])`
/// and must **never be regenerated**: it proves v1 files keep opening. After a
/// format change, add a new fixture (v2-…) instead.
enum V1Fixture {
    static let asset = AssetID(rawValue: "0B5E7C1A-0000-4000-8000-000000000001")

    static func image() -> CGImage? {
        // 64×48: red left half, blue right half, white 8 px band in the middle rows.
        guard let ctx = RenderSupport.makeBitmapContext(width: 64, height: 48) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
        ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 32, y: 0, width: 32, height: 48))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 20, width: 64, height: 8))
        return ctx.makeImage()
    }

    static func document() -> ProjectDocument {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var doc = ProjectDocument(
            baseImage: asset, pixelWidth: 64, pixelHeight: 48, scale: 2,
            source: CaptureSourceInfo(mode: "area", capturedAt: date, displayScale: 2),
            createdAt: date
        )
        func id(_ n: Int) -> UUID { UUID(uuidString: "00000000-0000-4000-8000-00000000000\(n)") ?? UUID() }
        doc.layers[0].id = id(9)
        doc.annotations = [
            Annotation(id: id(1), kind: .rectangle(RectShape(rect: CGRect(x: 4, y: 4, width: 20, height: 12), cornerRadius: 2)),
                       style: AnnotationStyle(color: .annotationPink, strokeWidth: 2, shadow: false)),
            Annotation(id: id(2), kind: .arrow(ArrowShape(start: CGPoint(x: 40, y: 8), end: CGPoint(x: 58, y: 20))),
                       style: AnnotationStyle(color: .annotationYellow, strokeWidth: 3)),
            Annotation(id: id(3), kind: .text(TextShape(text: "Hi", frame: CGRect(x: 4, y: 30, width: 30, height: 14),
                                                        fontSize: 12, textStyle: .boxed)),
                       style: AnnotationStyle(color: .annotationBlue)),
            Annotation(id: id(4), kind: .counter(CounterShape(center: CGPoint(x: 50, y: 38), number: 1, diameter: 12)),
                       style: AnnotationStyle(color: .annotationGreen)),
            Annotation(id: id(5), kind: .redaction(RedactionShape(rect: CGRect(x: 36, y: 28, width: 8, height: 6),
                                                                  method: .blackOut, strength: 0, seed: 1)),
                       style: AnnotationStyle(color: .black, shadow: false)),
        ]
        return doc
    }
}
