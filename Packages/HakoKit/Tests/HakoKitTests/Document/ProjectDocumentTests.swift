import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("ProjectDocument")
struct ProjectDocumentTests {
    @Test func roundTripsDocumentWithEveryAnnotationKind() throws {
        let doc = AnnotationFixtures.fullDocument()
        // Sanity: the fixture really covers every kind.
        #expect(Set(doc.annotations.map(\.kind.tag)) == Set(Annotation.KindTag.allCases))

        let data = try doc.jsonData()
        let decoded = try ProjectDocument(jsonData: data)
        #expect(decoded == doc)
        // Stable output: encoding again gives identical bytes.
        #expect(try decoded.jsonData() == data)
    }

    @Test func jsonCarriesSchemaVersionAndKindTags() throws {
        let data = try AnnotationFixtures.fullDocument().jsonData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["formatVersion"] as? Int == ProjectDocument.currentFormatVersion)
        #expect(ProjectDocument.currentFormatVersion == 1)
        let annotations = try #require(object["annotations"] as? [[String: Any]])
        let tags = Set(annotations.compactMap { $0["kind"] as? String })
        #expect(tags == Set(Annotation.KindTag.allCases.map(\.rawValue)))
        let style = try #require(annotations.first?["style"] as? [String: Any])
        #expect(style["color"] as? String == "#0A84FFFF")
    }

    @Test func rejectsNewerFormatVersion() throws {
        var object = try #require(
            try JSONSerialization.jsonObject(with: AnnotationFixtures.emptyDocument().jsonData()) as? [String: Any]
        )
        object["formatVersion"] = 99
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: ProjectDocumentError.unsupportedFormatVersion(99)) {
            try ProjectDocument(jsonData: data)
        }
    }

    @Test func missingFormatVersionFails() {
        let json = #"{"canvas":{"width":10,"height":10,"scale":1},"layers":[]}"#
        #expect(throws: (any Error).self) {
            try ProjectDocument(jsonData: Data(json.utf8))
        }
    }

    @Test func toleratesUnknownFieldsAndMissingOptionalSections() throws {
        let json = """
        {
          "formatVersion": 1,
          "futureField": {"x": 1},
          "canvas": {"width": 100, "height": 80, "scale": 2, "colorSpace": "p3"},
          "layers": [{"id": "6A1F6D2C-1B7B-4F6B-9E4B-0F5B5E7F7A11", "assetID": "A1", "frame": [[0, 0], [100, 80]]}]
        }
        """
        let doc = try ProjectDocument(jsonData: Data(json.utf8))
        #expect(doc.canvas == CanvasInfo(width: 100, height: 80, scale: 2))
        #expect(doc.annotations.isEmpty)
        #expect(doc.crop == nil)
        #expect(doc.transform == .identity)
        #expect(doc.background == nil)
        #expect(doc.layers.first?.assetID == AssetID(rawValue: "A1"))
    }

    @Test func unknownAnnotationKindFailsLoudly() {
        let json = """
        {"formatVersion": 1, "canvas": {"width": 1, "height": 1, "scale": 1}, "layers": [],
         "annotations": [{"id": "6A1F6D2C-1B7B-4F6B-9E4B-0F5B5E7F7A11", "kind": "hologram", "style": {}, "shape": {}}]}
        """
        #expect(throws: DecodingError.self) {
            try ProjectDocument(jsonData: Data(json.utf8))
        }
    }

    @Test func referencedAssetsIncludeLayersAndImages() {
        let doc = AnnotationFixtures.fullDocument()
        #expect(doc.referencedAssets == [AnnotationFixtures.baseAsset, AnnotationFixtures.extraAsset])
        #expect(AnnotationFixtures.baseAsset.bundlePath == "assets/\(AnnotationFixtures.baseAsset.rawValue).png")
    }

    @Test func singleImageInitializerCoversCanvas() {
        let doc = AnnotationFixtures.emptyDocument()
        #expect(doc.layers.count == 1)
        #expect(doc.layers.first?.frame == CGRect(x: 0, y: 0, width: 2000, height: 1200))
        #expect(doc.visibleRect == doc.canvas.rect)
        #expect(doc.formatVersion == ProjectDocument.currentFormatVersion)
    }

    @Test func nextCounterNumberUsesHighestPlusOne() {
        var doc = AnnotationFixtures.emptyDocument()
        #expect(doc.nextCounterNumber(start: 0) == 0)
        doc.annotations = [AnnotationFixtures.counter(1), AnnotationFixtures.counter(5), AnnotationFixtures.counter(2)]
        #expect(doc.nextCounterNumber(start: 1) == 6)
    }

    @Test func canvasTransformNormalizesQuarterTurns() {
        #expect(CanvasTransform(rotationQuarterTurns: 5).rotationQuarterTurns == 1)
        #expect(CanvasTransform(rotationQuarterTurns: -1).rotationQuarterTurns == 3)
    }

    @Test func colorHexRoundTrip() throws {
        let color = try #require(RGBAColor(hex: "#FF375F"))
        #expect(color.hexString == "#FF375FFF")
        #expect(RGBAColor(hex: "0A84FF80")?.hexString == "#0A84FF80")
        #expect(RGBAColor(hex: "#FFF") == .white)
        #expect(RGBAColor(hex: "nope") == nil)
        #expect(RGBAColor.white.contrastingColor == .black)
        #expect(RGBAColor.annotationBlue.contrastingColor == .white)
    }
}
