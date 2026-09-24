import AppKit
import CoreGraphics
import HakoKit
import Testing
@testable import HakoShot

@Suite("Crop math")
struct CropMathTests {
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func freeformCornerDragKeepsOppositeCorner() {
        let rect = CGRect(x: 100, y: 100, width: 400, height: 300)
        let out = CropMath.resize(rect, handle: .bottomRight, to: CGPoint(x: 700, y: 450), ratio: nil, bounds: bounds)
        #expect(out == CGRect(x: 100, y: 100, width: 600, height: 350))
        // Past the opposite edge: clamped to the minimum side, never flipped.
        let tiny = CropMath.resize(rect, handle: .left, to: CGPoint(x: 900, y: 200), ratio: nil, bounds: bounds)
        #expect(tiny.maxX == rect.maxX)
        #expect(tiny.width == CropMath.minimumSide)
        // Outside the image: clamped to it.
        let clamped = CropMath.resize(rect, handle: .topLeft, to: CGPoint(x: -50, y: -80), ratio: nil, bounds: bounds)
        #expect(clamped == CGRect(x: 0, y: 0, width: 500, height: 400))
    }

    @Test func ratioLockedCornerDrag() {
        let rect = CGRect(x: 0, y: 0, width: 160, height: 90)
        let out = CropMath.resize(rect, handle: .bottomRight, to: CGPoint(x: 480, y: 100), ratio: 16.0 / 9, bounds: bounds)
        #expect(out == CGRect(x: 0, y: 0, width: 480, height: 270))
        // Would exceed the height: limited by the bounds, ratio kept.
        let big = CropMath.resize(rect, handle: .bottomRight, to: CGPoint(x: 1000, y: 1000), ratio: 1, bounds: bounds)
        #expect(big == CGRect(x: 0, y: 0, width: 600, height: 600))
    }

    @Test func ratioLockedEdgeDragCentersOtherAxis() {
        let rect = CGRect(x: 100, y: 200, width: 200, height: 200)
        let out = CropMath.resize(rect, handle: .right, to: CGPoint(x: 400, y: 0), ratio: 1, bounds: bounds)
        #expect(out.width == 300)
        #expect(out.height == 300)
        #expect(out.minX == 100)
        #expect(out.midY == 300)
    }

    @Test func snapsToTargetsWithinTolerance() {
        let targets = CropSnapTargets(bounds: bounds, rects: [CGRect(x: 250, y: 120, width: 100, height: 100)])
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let snapped = CropMath.resize(rect, handle: .right, to: CGPoint(x: 246, y: 0), ratio: nil, bounds: bounds,
                                      snap: targets, tolerance: 6)
        #expect(snapped.maxX == 250)
        let free = CropMath.resize(rect, handle: .right, to: CGPoint(x: 240, y: 0), ratio: nil, bounds: bounds,
                                   snap: targets, tolerance: 6)
        #expect(free.maxX == 240)
        // Moving: the nearer edge snaps; never leaves the image.
        let moved = CropMath.move(rect, by: CGVector(dx: 147, dy: 0), bounds: bounds, snap: targets, tolerance: 6)
        #expect(moved.maxX == 350)
        let out = CropMath.move(rect, by: CGVector(dx: 5000, dy: -40), bounds: bounds)
        #expect(out == CGRect(x: 800, y: 0, width: 200, height: 200))
    }

    @Test func fittingARatioAndTypingASize() {
        #expect(CropMath.fitted(ratio: 16.0 / 9, in: bounds) == CGRect(x: 0, y: 19, width: 1000, height: 562))
        #expect(CropMath.fitted(ratio: 1, in: bounds) == CGRect(x: 200, y: 0, width: 600, height: 600))
        let typed = CropMath.resized(CGRect(x: 400, y: 200, width: 200, height: 200), width: 300, height: 5000, bounds: bounds)
        #expect(typed == CGRect(x: 350, y: 0, width: 300, height: 600))
    }

    @Test func handleHitTesting() {
        let rect = CGRect(x: 100, y: 100, width: 200, height: 100)
        #expect(CropMath.handle(at: CGPoint(x: 103, y: 98), of: rect, tolerance: 8) == .topLeft)
        #expect(CropMath.handle(at: CGPoint(x: 180, y: 204), of: rect, tolerance: 8) == .bottom)
        #expect(CropMath.handle(at: CGPoint(x: 200, y: 150), of: rect, tolerance: 8) == nil)
    }

    @Test func displayRectRoundTripsThroughRotation() {
        var doc = ProjectDocument(baseImage: AssetID(), pixelWidth: 800, pixelHeight: 400, scale: 2)
        doc.transform = CanvasTransform(rotationQuarterTurns: 1, flipHorizontal: true)
        #expect(CropMath.displayBounds(of: doc).size == CGSize(width: 400, height: 800))
        let display = CGRect(x: 50, y: 100, width: 200, height: 300)
        let canvas = CropMath.canvasCrop(for: display, in: doc)
        #expect(canvas?.size == CGSize(width: 300, height: 200))
        doc.crop = canvas
        #expect(CropMath.displayRect(of: doc) == display)
        // The whole image means "no crop".
        #expect(CropMath.canvasCrop(for: CropMath.displayBounds(of: doc), in: doc) == nil)
    }
}

@Suite("Crop mode + background in the editor")
@MainActor
final class CropBackgroundModelTests {
    private var suites: [String] = []

    deinit {
        for suite in suites { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func makeModel(width: Int = 400, height: Int = 200) -> EditorViewModel {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context?.makeImage() else { fatalError("no test image") }
        // Scratch suite, removed when the test ends.
        let suite = "com.hakanyucel.hakoshot.tests.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return EditorViewModel(image: image, scale: 2, mode: .area, settings: AppSettings(defaults: defaults))
    }

    @Test func applyingACropIsOneUndoStepAndNonDestructive() {
        let model = makeModel()
        model.selectTool(.crop)
        #expect(model.cropSession?.rect == CGRect(x: 0, y: 0, width: 400, height: 200))
        model.updateCrop { $0.setAspect(.ratio(width: 1, height: 1)) }
        #expect(model.cropSession?.rect == CGRect(x: 100, y: 0, width: 200, height: 200))
        let depth = model.store.undoDepth
        model.applyCrop()
        #expect(!model.isCropping)
        #expect(model.document.crop == CGRect(x: 100, y: 0, width: 200, height: 200))
        #expect(model.store.undoDepth == depth + 1)
        #expect(model.store.undoActionName == "Crop")
        // Re-entering shows the whole image with the current crop.
        model.beginCrop()
        #expect(model.cropSession?.bounds.size == CGSize(width: 400, height: 200))
        #expect(model.cropSession?.rect == CGRect(x: 100, y: 0, width: 200, height: 200))
        model.cancelCrop()
        #expect(model.document.crop != nil)
        model.undo()
        #expect(model.document.crop == nil)
    }

    @Test func rotatingInCropModeKeepsTheArea() {
        let model = makeModel()
        model.beginCrop()
        model.updateCrop { $0.rect = CGRect(x: 0, y: 0, width: 100, height: 50) }
        model.rotate(clockwise: true)
        #expect(model.document.transform.rotationQuarterTurns == 1)
        #expect(model.cropSession?.bounds.size == CGSize(width: 200, height: 400))
        #expect(model.cropSession?.rect == CGRect(x: 150, y: 0, width: 50, height: 100))
        model.applyCrop()
        #expect(model.document.crop == CGRect(x: 0, y: 0, width: 100, height: 50))
        #expect(DocumentRenderer.contentSize(of: model.document) == CGSize(width: 50, height: 100))
    }

    @Test func backgroundGeometryMapsClicksBackToTheCanvas() {
        let model = makeModel()
        model.setBackgroundEnabled(true)
        model.updateBackground { $0.autoBalance = false; $0.padding = 64 }
        let doc = model.document
        let geometry = CanvasDisplay.geometry(for: doc, mode: .output) { model.renderer.outputLayout(of: doc) }
        // 64 pt × scale 2 on each side.
        #expect(geometry.canvasSize == CGSize(width: 400 + 256, height: 200 + 256))
        #expect(geometry.viewSize.width == (400 + 256) / 2 + 2 * geometry.margin)
        let p = CGPoint(x: 37, y: 150)
        let view = geometry.viewPoint(fromCanvas: p)
        #expect(view == CGPoint(x: geometry.margin + (37 + 128) / 2, y: geometry.margin + (150 + 128) / 2))
        let back = geometry.canvasPoint(fromView: view)
        #expect(abs(back.x - p.x) < 0.001 && abs(back.y - p.y) < 0.001)
        #expect(CanvasDisplay.mode(for: doc, cropping: false) == .output)
        #expect(CanvasDisplay.mode(for: doc, cropping: true) == .crop)
        // Export is the same size.
        let image = model.renderer.makeImage(doc)
        #expect(image?.width == 656 && image?.height == 456)
    }

    @Test func sliderDragIsOneUndoStepAndOffRemembersStyle() {
        let model = makeModel()
        model.setBackgroundEnabled(true)
        let depth = model.store.undoDepth
        model.beginBackgroundEdit()
        for padding in stride(from: 70.0, through: 120, by: 10) { model.updateBackground { $0.padding = padding } }
        model.endBackgroundEdit()
        #expect(model.store.undoDepth == depth + 1)
        #expect(model.background?.padding == 120)
        model.setBackgroundEnabled(false)
        #expect(model.background == nil)
        model.setBackgroundEnabled(true)
        #expect(model.background?.padding == 120)
    }

    @Test func presetsRoundTripAndDropImageFills() {
        var style = BackgroundStyle.standard
        style.fill = .image(AssetID())
        style.padding = 20
        let presets = [BackgroundPreset(name: "A", style: BackgroundPresetStore.portable(style))]
        let decoded = BackgroundPresetStore.decode(BackgroundPresetStore.encode(presets))
        #expect(decoded == presets)
        #expect(decoded.first?.style.fill == BackgroundStyle.standard.fill)
        #expect(decoded.first?.style.padding == 20)
        #expect(BackgroundPresetStore.decode("garbage").isEmpty)
        #expect(BackgroundPresetStore.nextName(after: presets) == "Preset 2")

        let model = makeModel()
        model.setBackgroundEnabled(true)
        model.saveBackgroundPreset()
        #expect(model.backgroundPresets.count == 1)
        model.setBackgroundEnabled(false)
        if let preset = model.backgroundPresets.first { model.applyBackgroundPreset(preset) }
        #expect(model.background != nil)
    }

    @Test func imageFillAssetIsKeptForSaving() {
        let model = makeModel()
        guard let image = model.renderer.makeImage(model.document) else { return }
        let id = model.addAsset(image)
        model.setBackgroundFill(.image(id))
        #expect(model.document.referencedAssets.contains(id))
        #expect(model.assets[id] != nil)
        #expect(model.renderer.assets(id) != nil)
    }
}
