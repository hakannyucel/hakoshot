import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

@MainActor
@Suite("Editor canvas operations (WP5.4)")
struct CanvasOpsTests {
    private func makeImage(_ width: Int, _ height: Int, gray: CGFloat = 0.5) throws -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: gray, green: 0.3, blue: 0.8, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context?.makeImage())
    }

    private func pngData(_ image: CGImage) throws -> Data {
        try ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions.defaults(for: .png, scale: 1))
    }

    // MARK: Shortcuts

    @Test func combineShortcuts() {
        #expect(EditorShortcuts.commandShortcut(for: EditorKeyInput(characters: "i", command: true)) == .addImage)
        #expect(EditorShortcuts.commandShortcut(for: EditorKeyInput(characters: "i", command: true, shift: true)) == .addScreenshot)
    }

    // MARK: Pure helpers

    @Test func pastePlacementRule() {
        let visible = CGSize(width: 2000, height: 1200)
        #expect(EditorViewModel.pastesAsOverlay(imageSize: CGSize(width: 400, height: 300), visible: visible))
        #expect(!EditorViewModel.pastesAsOverlay(imageSize: CGSize(width: 2000, height: 1200), visible: visible))
        #expect(!EditorViewModel.pastesAsOverlay(imageSize: CGSize(width: 2100, height: 10), visible: visible))
    }

    @Test func dropEdgeFromPoint() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)
        #expect(EditorViewModel.combineEdge(for: CGPoint(x: 500, y: 300), visible: visible) == nil)
        #expect(EditorViewModel.combineEdge(for: CGPoint(x: 1050, y: 300), visible: visible) == .right)
        #expect(EditorViewModel.combineEdge(for: CGPoint(x: -20, y: 300), visible: visible) == .left)
        #expect(EditorViewModel.combineEdge(for: CGPoint(x: 1010, y: 700), visible: visible) == .bottom)
        #expect(EditorViewModel.combineEdge(for: CGPoint(x: 500, y: -5), visible: visible) == .top)
    }

    @Test func displayedEdgesAndAnchorsFollowRotation() {
        var doc = ProjectDocument(baseImage: AssetID(), pixelWidth: 400, pixelHeight: 200, scale: 2)
        #expect(EditorViewModel.canvasEdge(forDisplayed: .right, in: doc) == .right)
        doc.transform = CanvasTransform(rotationQuarterTurns: 1) // clockwise: canvas top → display right
        #expect(EditorViewModel.canvasEdge(forDisplayed: .right, in: doc) == .top)
        #expect(EditorViewModel.canvasEdge(forDisplayed: .bottom, in: doc) == .right)
        #expect(EditorViewModel.canvasAnchor(forDisplayed: .center, in: doc) == .center)
        #expect(EditorViewModel.canvasAnchor(forDisplayed: .topRight, in: doc) == .topLeft)
        doc.transform = CanvasTransform(flipHorizontal: true)
        #expect(EditorViewModel.canvasEdge(forDisplayed: .right, in: doc) == .left)
        #expect(EditorViewModel.canvasAnchor(forDisplayed: .topLeft, in: doc) == .topRight)
        #expect(EditorViewModel.canvasAxes(CGSize(width: 300, height: 100), turns: 1) == (100, 300))
        #expect(EditorViewModel.canvasAxes(CGSize(width: 300, height: 100), turns: 2) == (300, 100))
    }

    @Test func uprightTextEditorRectKeepsTextSize() {
        let geometry = CanvasGeometry(
            canvasSize: CGSize(width: 200, height: 400), scale: 2, margin: 10,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 200, ty: 0)
        )
        let frame = CGRect(x: 20, y: 40, width: 100, height: 20)
        let turned = TextEditingController.editorRect(for: frame, geometry: geometry, upright: false)
        #expect(turned.size == CGSize(width: 10, height: 50)) // rotated bounding box
        let upright = TextEditingController.editorRect(for: frame, geometry: geometry, upright: true)
        #expect(upright.size == CGSize(width: 50, height: 10))
        #expect(abs(upright.midX - turned.midX) < 0.001 && abs(upright.midY - turned.midY) < 0.001)
    }

    // MARK: Model

    @Test func combineTwoImagesIsOneUndoStepAndExportsCombinedSize() throws {
        let model = EditorViewModel(image: try makeImage(300, 200), scale: 2, mode: .area)
        model.combine([(try makeImage(100, 250, gray: 0.9), nil), (try makeImage(50, 50, gray: 0.1), 1)])
        let doc = model.document
        // 300 + 100 + (50 px @1x → 100 px @2x) wide, tallest is 250.
        #expect(doc.canvas.width == 500 && doc.canvas.height == 250)
        #expect(doc.annotations.filter { $0.kind.tag == .image }.map(\.bounds) == [
            CGRect(x: 300, y: 0, width: 100, height: 250), CGRect(x: 400, y: 0, width: 100, height: 100),
        ])
        #expect(model.store.undoDepth == 1)
        #expect(model.store.undoActionName == "Combine Images")
        #expect(model.tool == .move)
        #expect(model.selection.count == 1)
        let rendered = try #require(model.renderImage())
        #expect(rendered.width == 500 && rendered.height == 250)
        #expect(CanvasView.hasUncoveredArea(doc))
        model.undo()
        #expect(model.document.canvas.width == 300)
        #expect(!CanvasView.hasUncoveredArea(model.document))
    }

    @Test func pasteImageOverlayOrCombine() throws {
        let model = EditorViewModel(image: try makeImage(400, 300), scale: 1, mode: .area)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hakoshot.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        #expect(!model.pasteImage(from: pasteboard))

        pasteboard.setData(try pngData(try makeImage(40, 30)), forType: .png)
        #expect(model.pasteImage(from: pasteboard))
        #expect(model.document.canvas.width == 400)
        #expect(model.document.annotations.last?.bounds == CGRect(x: 180, y: 135, width: 40, height: 30))

        pasteboard.clearContents()
        pasteboard.setData(try pngData(try makeImage(400, 300)), forType: .png)
        #expect(model.pasteImage(from: pasteboard))
        #expect(model.document.canvas.width == 800)
    }

    @Test func copiedImageAnnotationPastesAsObjectAndAsPNG() throws {
        let model = EditorViewModel(image: try makeImage(400, 300), scale: 1, mode: .area)
        model.combine([(try makeImage(60, 60), nil)])
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("hakoshot.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(model.copySelectionToPasteboard(pasteboard))
        #expect(pasteboard.data(forType: .png) != nil)
        #expect(model.pasteFromPasteboard(pasteboard))
        #expect(model.document.annotations.filter { $0.kind.tag == .image }.count == 2)

        // Another editor lacks the asset: object paste declines, the PNG path works.
        let other = EditorViewModel(image: try makeImage(400, 300), scale: 1, mode: .area)
        #expect(!other.pasteFromPasteboard(pasteboard))
        #expect(other.pasteImage(from: pasteboard))
        #expect(other.document.annotations.count == 1)
    }

    @Test func resizeAndCanvasSizeThroughModel() throws {
        let model = EditorViewModel(image: try makeImage(400, 300), scale: 2, mode: .area)
        model.resizeCanvas(toDisplayed: CGSize(width: 500, height: 400), anchor: .center)
        #expect(model.document.layers.first?.frame.origin == CGPoint(x: 50, y: 50))
        model.resizeImage(toDisplayed: CGSize(width: 250, height: 200))
        #expect(model.outputContentSize == CGSize(width: 250, height: 200))
        #expect(model.canvasScale == 1)
        let rendered = try #require(model.renderImage())
        #expect(rendered.width == 250 && rendered.height == 200)
        #expect(model.store.undoDepth == 2)
    }

    @Test func combinedProjectRoundTrips() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "CanvasOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorViewModel(image: try makeImage(300, 200), scale: 2, mode: .area)
        model.combine([(try makeImage(120, 80, gray: 0.9), nil)])
        let url = folder.appending(path: "Combined.hakoshot")
        try model.writeProject(to: url)
        let contents = try ProjectFile.read(from: url)
        // createdAt loses sub-second precision in ISO-8601; compare the rest.
        #expect(contents.document.annotations == model.document.annotations)
        #expect(contents.document.canvas == model.document.canvas)
        #expect(contents.document.layers == model.document.layers)
        #expect(Set(contents.assets.keys) == model.document.referencedAssets)
        let reopened = try #require(EditorViewModel(project: contents, projectURL: url))
        #expect(reopened.baseImage.width == 300)
        let image = try #require(reopened.renderImage())
        #expect(image.width == 420 && image.height == 200)
    }
}
