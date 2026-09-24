import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("CanvasOperations (WP5.4)")
struct CanvasOperationsTests {
    private static func image(_ w: Double, _ h: Double, at origin: CGPoint = .zero, asset: AssetID = AnnotationFixtures.extraAsset) -> Annotation {
        Annotation(kind: .image(ImageShape(assetID: asset, frame: CGRect(origin: origin, size: CGSize(width: w, height: h)))),
                   style: AnnotationStyle(shadow: false))
    }

    private static func state(_ annotations: [Annotation] = []) -> EditorState {
        var doc = AnnotationFixtures.emptyDocument() // 2000 × 1200 @2x
        doc.annotations = annotations
        return EditorState(document: doc)
    }

    // MARK: Combine

    @Test func combineRightGrowsCanvasAndSelects() {
        let img = Self.image(800, 1600, at: CGPoint(x: 55, y: 77))
        let s = EditorReducer.reduce(Self.state(), .combineImage(img))
        #expect(s.document.canvas.width == 2800)
        #expect(s.document.canvas.height == 1600)
        #expect(s.document.layers.first?.frame == CGRect(x: 0, y: 0, width: 2000, height: 1200))
        #expect(s.document.annotations.last?.bounds == CGRect(x: 2000, y: 0, width: 800, height: 1600))
        #expect(s.selection == [img.id])
        #expect(s.document.referencedAssets.contains(AnnotationFixtures.extraAsset))
    }

    @Test func combineLeftAndTopMoveExistingContent() {
        let rect = AnnotationFixtures.rect(10, 20, 100, 50)
        let left = EditorReducer.reduce(Self.state([rect]), .combineImage(Self.image(500, 500), edge: .left, spacing: 20))
        #expect(left.document.canvas.width == 2520)
        #expect(left.document.canvas.height == 1200)
        #expect(left.document.layers.first?.frame.origin == CGPoint(x: 520, y: 0))
        #expect(left.document.annotations.first?.bounds.origin == CGPoint(x: 530, y: 20))
        #expect(left.document.annotations.last?.bounds == CGRect(x: 0, y: 0, width: 500, height: 500))

        let top = EditorReducer.reduce(Self.state(), .combineImage(Self.image(3000, 100), edge: .top))
        #expect(top.document.canvas.width == 3000)
        #expect(top.document.canvas.height == 1300)
        #expect(top.document.layers.first?.frame.origin == CGPoint(x: 0, y: 100))
    }

    @Test func combineBesideCropExtendsCrop() {
        var s = Self.state()
        s.document.crop = CGRect(x: 100, y: 100, width: 1000, height: 600)
        s = EditorReducer.reduce(s, .combineImage(Self.image(400, 300)))
        #expect(s.document.canvas.width == 2000) // fits: no growth
        #expect(s.document.annotations.last?.bounds == CGRect(x: 1100, y: 100, width: 400, height: 300))
        #expect(s.document.crop == CGRect(x: 100, y: 100, width: 1400, height: 600))
    }

    @Test func insertImageOutsideCanvasShiftsEverything() {
        let rect = AnnotationFixtures.rect(0, 0, 10, 10)
        var s = Self.state([rect])
        s.document.crop = CGRect(x: 0, y: 0, width: 500, height: 500)
        s = EditorReducer.reduce(s, .insertImage(Self.image(300, 300, at: CGPoint(x: -100, y: 1000))))
        #expect(s.document.canvas.width == 2100)
        #expect(s.document.canvas.height == 1300)
        #expect(s.document.layers.first?.frame.origin == CGPoint(x: 100, y: 0))
        #expect(s.document.annotations.first?.bounds.origin == CGPoint(x: 100, y: 0))
        #expect(s.document.annotations.last?.bounds == CGRect(x: 0, y: 1000, width: 300, height: 300))
        #expect(s.document.crop == CGRect(x: 0, y: 0, width: 600, height: 1300))
        // Inside the canvas: nothing grows.
        let inside = EditorReducer.reduce(Self.state(), .insertImage(Self.image(10, 10, at: CGPoint(x: 5, y: 5)), select: false))
        #expect(inside.document.canvas.width == 2000)
        #expect(inside.selection.isEmpty)
    }

    @MainActor @Test func combineIsOneUndoStep() {
        let store = EditorStore(document: AnnotationFixtures.emptyDocument())
        let before = store.document
        store.apply(.combineImage(Self.image(800, 600)))
        #expect(store.undoDepth == 1)
        #expect(store.undoActionName == "Combine Images")
        store.undo()
        #expect(store.document == before)
        store.redo()
        #expect(store.document.canvas.width == 2800)
    }

    @Test func combinedDocumentRendersAtCanvasSize() throws {
        var doc = RenderFixtures.document(width: 40, height: 30)
        doc = CanvasOperations.insertingImage(
            Self.image(20, 50, at: CGPoint(x: 40, y: 0), asset: RenderFixtures.extra), into: doc
        )
        let renderer = RenderFixtures.renderer(
            base: RenderFixtures.solid(.white, width: 40, height: 30),
            extra: RenderFixtures.solid(.black, width: 20, height: 50)
        )
        let pixels = try #require(RenderFixtures.render(doc, with: renderer))
        #expect(pixels.width == 60 && pixels.height == 50)
        #expect(pixels.pixel(5, 5) == RGBA(r: 255, g: 255, b: 255))
        #expect(pixels.pixel(50, 40) == RGBA(r: 0, g: 0, b: 0))
        #expect(pixels.pixel(5, 45).a == 0) // expanded area is transparent
    }

    // MARK: Canvas size

    @Test func resizeCanvasAnchors() {
        let rect = AnnotationFixtures.rect(10, 10, 20, 20)
        let center = EditorReducer.reduce(Self.state([rect]), .resizeCanvas(width: 2400, height: 1400, anchor: .center))
        #expect(center.document.canvas.width == 2400 && center.document.canvas.height == 1400)
        #expect(center.document.layers.first?.frame.origin == CGPoint(x: 200, y: 100))
        #expect(center.document.annotations.first?.bounds.origin == CGPoint(x: 210, y: 110))

        let topLeft = EditorReducer.reduce(Self.state([rect]), .resizeCanvas(width: 2400, height: 1400, anchor: .topLeft))
        #expect(topLeft.document.layers.first?.frame.origin == .zero)
        let bottomRight = EditorReducer.reduce(Self.state(), .resizeCanvas(width: 2400, height: 1400, anchor: .bottomRight))
        #expect(bottomRight.document.layers.first?.frame.origin == CGPoint(x: 400, y: 200))
    }

    @Test func shrinkingCanvasClipsCrop() {
        var s = Self.state()
        s.document.crop = CGRect(x: 1500, y: 0, width: 400, height: 400)
        s = EditorReducer.reduce(s, .resizeCanvas(width: 1600, height: 1200, anchor: .topLeft))
        #expect(s.document.crop == CGRect(x: 1500, y: 0, width: 100, height: 400))
        s = EditorReducer.reduce(s, .resizeCanvas(width: 1000, height: 1200, anchor: .topLeft))
        #expect(s.document.crop == nil) // crop fell off the canvas
        #expect(s.document.canvas.width == 1000)
    }

    // MARK: Resize image

    @Test func resizeImageScalesEverything() throws {
        let text = Annotation(kind: .text(TextShape(text: "Hi", frame: CGRect(x: 100, y: 100, width: 200, height: 60), fontSize: 40)),
                              style: AnnotationStyle())
        let counter = AnnotationFixtures.counter(1, at: CGPoint(x: 400, y: 400))
        let rect = AnnotationFixtures.rect(100, 200, 300, 400, width: 12)
        let s = EditorReducer.reduce(Self.state([text, counter, rect]), .resizeImage(width: 1000, height: 600))
        let doc = s.document
        #expect(doc.canvas.width == 1000 && doc.canvas.height == 600)
        #expect(doc.canvas.scale == 1)
        #expect(doc.layers.first?.frame == CGRect(x: 0, y: 0, width: 1000, height: 600))
        #expect(doc.annotations[2].bounds == CGRect(x: 50, y: 100, width: 150, height: 200))
        #expect(doc.annotations[2].style.strokeWidth == 6)
        guard case .text(let t) = doc.annotations[0].kind, case .counter(let c) = doc.annotations[1].kind else {
            Issue.record("kinds changed")
            return
        }
        #expect(t.fontSize == 20)
        #expect(c.center == CGPoint(x: 200, y: 200))
        #expect(c.diameter == 30)
        #expect(DocumentRenderer.contentSize(of: doc) == CGSize(width: 1000, height: 600))
    }

    @Test func resizeImageWithCropAndAspectChange() {
        var s = Self.state()
        s.document.crop = CGRect(x: 100, y: 100, width: 1000, height: 600)
        s = EditorReducer.reduce(s, .resizeImage(width: 500, height: 300))
        #expect(s.document.crop == CGRect(x: 50, y: 50, width: 500, height: 300))
        #expect(s.document.canvas.width == 1000)
        #expect(DocumentRenderer.contentSize(of: s.document) == CGSize(width: 500, height: 300))

        // Unlocked aspect: independent axes.
        let stretched = EditorReducer.reduce(Self.state(), .resizeImage(width: 3000, height: 1200))
        #expect(stretched.document.canvas.width == 3000 && stretched.document.canvas.height == 1200)
        #expect(stretched.document.layers.first?.frame.width == 3000)
        // Same size: no change (no undo step).
        let same = Self.state()
        #expect(EditorReducer.reduce(same, .resizeImage(width: 2000, height: 1200)) == same)
    }

    // MARK: Persistence

    @Test func combinedAndResizedDocumentRoundTripsThroughProjectFile() throws {
        let dir = try ProjectFileTests.makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let second = AssetID(rawValue: "7F3A0C2E-0000-4000-8000-0000000000C3")
        var s = Self.state([AnnotationFixtures.rect(10, 10, 100, 100)])
        s = EditorReducer.reduce(s, .combineImage(Self.image(40, 30)))
        s = EditorReducer.reduce(s, .combineImage(Self.image(60, 60, asset: second), edge: .bottom, spacing: 16))
        s = EditorReducer.reduce(s, .resizeCanvas(width: s.document.canvas.width + 20, height: s.document.canvas.height + 20, anchor: .center))
        s = EditorReducer.reduce(s, .resizeImage(width: s.document.canvas.width / 2, height: s.document.canvas.height / 2))
        let doc = s.document
        #expect(doc.annotations.filter { $0.kind.tag == .image }.count == 2)

        let assets: [AssetID: CGImage] = try [
            AnnotationFixtures.baseAsset: #require(RenderFixtures.pattern(width: 2000, height: 1200)),
            AnnotationFixtures.extraAsset: #require(RenderFixtures.solid(.annotationBlue, width: 40, height: 30)),
            second: #require(RenderFixtures.solid(.annotationGreen, width: 60, height: 60)),
        ]
        let url = dir.appendingPathComponent("Combined.hakoshot")
        try ProjectFile.write(doc, assets: assets, to: url)
        let read = try ProjectFile.read(from: url)
        #expect(read.document == doc)
        #expect(Set(read.assets.keys) == [AnnotationFixtures.baseAsset, AnnotationFixtures.extraAsset, second])
    }
}
