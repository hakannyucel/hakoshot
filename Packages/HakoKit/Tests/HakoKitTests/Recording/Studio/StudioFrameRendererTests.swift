import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import HakoKit

@Suite("StudioFrameRenderer")
struct StudioFrameRendererTests {
    // Source 200×100 (y down): TL red, TR green, BL blue, BR yellow.
    static let red = RGBAColor(red: 1, green: 0, blue: 0)
    static let green = RGBAColor(red: 0, green: 1, blue: 0)
    static let blue = RGBAColor(red: 0, green: 0, blue: 1)
    static let yellow = RGBAColor(red: 1, green: 1, blue: 0)
    static let backdrop = RGBAColor(red: 0.2, green: 0.4, blue: 0.6)

    static func quadrantSource() -> CIImage {
        let context = RenderSupport.makeBitmapContext(width: 200, height: 100)!
        RenderSupport.flipToTopLeft(context, height: 100)
        for (color, rect) in [(red, CGRect(x: 0, y: 0, width: 100, height: 50)),
                              (green, CGRect(x: 100, y: 0, width: 100, height: 50)),
                              (blue, CGRect(x: 0, y: 50, width: 100, height: 50)),
                              (yellow, CGRect(x: 100, y: 50, width: 100, height: 50))] {
            context.setFillColor(color.cgColor)
            context.fill(rect)
        }
        return CIImage(cgImage: context.makeImage()!)
    }

    static func solidSource(_ color: RGBAColor) -> CIImage {
        CIImage(color: StudioFrameRenderer.ciColor(color)).cropped(to: CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    /// Canvas 320×200, content 240×120 at (40, 40): 1.2 canvas px per source px.
    static func state(corner: Double = 16, shadow: BackgroundShadow = .none,
                      view: CGRect = CGRect(x: 0, y: 0, width: 200, height: 100)) -> StudioFrameState {
        StudioFrameState(
            outputTime: 0, sourceTime: 0, canvasSize: CGSize(width: 320, height: 200), lengthScale: 1,
            background: .solid(backdrop), contentRect: CGRect(x: 40, y: 40, width: 240, height: 120),
            cornerRadius: corner, shadow: shadow, viewRect: view, zoomScale: 200 / view.width,
            cursor: nil, clickEffects: [], camera: nil
        )
    }

    struct Pixels {
        let width: Int
        let height: Int
        let data: [UInt8]

        init(_ image: CIImage) throws {
            let cg = try #require(StudioFrameRenderer.makeCGImage(image))
            width = cg.width
            height = cg.height
            let context = try #require(RenderSupport.makeBitmapContext(width: width, height: height))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            let buffer = try #require(context.data).assumingMemoryBound(to: UInt8.self)
            data = Array(UnsafeBufferPointer(start: buffer, count: context.bytesPerRow * height))
            bytesPerRow = context.bytesPerRow
        }

        let bytesPerRow: Int

        /// Canvas pixel (y down) as 0…255 RGBA.
        func at(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
            let i = y * bytesPerRow + x * 4
            return (Int(data[i]), Int(data[i + 1]), Int(data[i + 2]), Int(data[i + 3]))
        }

        func matches(_ x: Int, _ y: Int, _ c: RGBAColor, tolerance: Int = 3) -> Bool {
            let p = at(x, y)
            return abs(p.r - Int((c.red * 255).rounded())) <= tolerance
                && abs(p.g - Int((c.green * 255).rounded())) <= tolerance
                && abs(p.b - Int((c.blue * 255).rounded())) <= tolerance
        }
    }

    let renderer = StudioFrameRenderer()

    @Test func paddingShowsBackgroundAndQuadrantsAreUpright() throws {
        let image = renderer.render(source: Self.quadrantSource(), state: Self.state())
        #expect(image.extent == CGRect(x: 0, y: 0, width: 320, height: 200))
        let px = try Pixels(image)
        #expect(px.matches(20, 100, Self.backdrop))
        #expect(px.matches(160, 20, Self.backdrop))
        #expect(px.matches(160, 180, Self.backdrop))
        // Content quadrants in the source's orientation (y down).
        #expect(px.matches(100, 70, Self.red))
        #expect(px.matches(220, 70, Self.green))
        #expect(px.matches(100, 130, Self.blue))
        #expect(px.matches(220, 130, Self.yellow))
    }

    @Test func cornersAreRounded() throws {
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), state: Self.state(corner: 16)))
        #expect(px.matches(0, 0, Self.backdrop))
        #expect(px.matches(319, 199, Self.backdrop))
        // Content corner pixels fall outside the 16 px rounding.
        #expect(px.matches(41, 41, Self.backdrop))
        #expect(px.matches(278, 158, Self.backdrop))
        #expect(px.matches(41, 60, Self.red))
        // Square corners without a radius.
        let square = try Pixels(renderer.render(source: Self.quadrantSource(), state: Self.state(corner: 0)))
        #expect(square.matches(41, 41, Self.red))
    }

    @Test func shadowDarkensBelowTheCard() throws {
        let shadow = BackgroundShadow(opacity: 0.5, radius: 12, offsetX: 0, offsetY: 8)
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), state: Self.state(shadow: shadow)))
        let below = px.at(160, 165), above = px.at(160, 35)
        #expect(below.b < 140) // darker than the 153 backdrop
        #expect(below.b < above.b)
        #expect(px.matches(5, 5, Self.backdrop))
    }

    @Test func nineSixteenProjectGivesPortraitCanvas() throws {
        var project = V1StudioFixture.project()
        project.canvas.aspectRatio = .nineSixteen
        let state = StudioFrameState.make(project: project, metadata: nil, cursorPath: nil, outputTime: 0)
        let source = CIImage(color: .red).cropped(to: CGRect(origin: .zero, size: project.source.pixelSize))
        let image = renderer.render(source: source, state: state)
        #expect(image.extent.origin == .zero)
        #expect(image.extent.size == project.canvasPixelSize)
        #expect(abs(image.extent.width / image.extent.height - 9.0 / 16.0) < 0.01)
        let cg = try #require(StudioFrameRenderer.makeCGImage(image))
        #expect(cg.width == Int(project.canvasPixelSize.width) && cg.height == Int(project.canvasPixelSize.height))
    }

    @Test func zoomedViewShowsTopLeftQuadrant() throws {
        let state = Self.state(view: CGRect(x: 0, y: 0, width: 100, height: 50))
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), state: state))
        #expect(px.matches(160, 100, Self.red))
        #expect(px.matches(270, 150, Self.red))
        // A view on the bottom-right quadrant.
        let br = Self.state(view: CGRect(x: 100, y: 50, width: 100, height: 50))
        #expect(try Pixels(renderer.render(source: Self.quadrantSource(), state: br)).matches(160, 100, Self.yellow))
    }

    @Test func cursorSpriteLandsAtHotSpot() throws {
        var state = Self.state()
        state.cursor = StudioCursorState(position: CGPoint(x: 100, y: 70), sourcePosition: .zero,
                                         shapeIndex: 0, scale: 2, opacity: 1)
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), state: state))
        // Arrow body 2 pt right, 8 pt below the tip: black over red.
        let body = px.at(104, 86)
        #expect(body.r < 60 && body.g < 60 && body.b < 60)
        // Above-left of the hot spot stays content.
        #expect(px.matches(90, 60, Self.red))

        // A recorded sprite: 4×4 pt green square, hot spot at its center.
        let ctx = RenderSupport.makeBitmapContext(width: 8, height: 8)!
        ctx.setFillColor(Self.green.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let sprite = StudioCursorSprite(image: ctx.makeImage()!, hotSpot: CGPoint(x: 2, y: 2), size: CGSize(width: 4, height: 4))
        let custom = try Pixels(renderer.render(source: Self.quadrantSource(), state: state) { _ in sprite })
        #expect(custom.matches(97, 67, Self.green))
        #expect(custom.matches(103, 73, Self.green))
        #expect(custom.matches(110, 70, Self.red))
    }

    @Test func clickRingIsBlue() throws {
        var state = Self.state()
        state.clickEffects = [StudioClickEffectState(position: CGPoint(x: 100, y: 70), progress: 0.3,
                                                     radius: 22, opacity: 0.7, button: .left)]
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), state: state))
        let bluish = (118...126).contains { x in
            let p = px.at(x, 70)
            return p.b > 150 && p.b > p.r + 40
        }
        #expect(bluish)
        #expect(px.matches(100, 70, Self.red)) // hollow center
        #expect(px.matches(135, 70, Self.red))
    }

    @Test func cameraIsMaskedToCircle() throws {
        var state = Self.state()
        state.camera = StudioCameraLayout(rect: CGRect(x: 200, y: 100, width: 60, height: 60), shape: .circle,
                                          cornerRadius: 30, mirrored: true, sourceTime: 0)
        let cyan = RGBAColor(red: 0, green: 1, blue: 1)
        let camera = CIImage(color: StudioFrameRenderer.ciColor(cyan)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), camera: camera, state: state))
        #expect(px.matches(230, 130, cyan))
        #expect(px.matches(202, 102, Self.yellow)) // outside the circle: content
        #expect(px.matches(257, 157, Self.yellow))
        // No layout → no camera.
        let none = try Pixels(renderer.render(source: Self.quadrantSource(), camera: camera, state: Self.state()))
        #expect(none.matches(230, 130, Self.yellow))
    }

    @Test func motionBlurAveragesSamples() throws {
        var state = Self.state(corner: 0)
        state.contentRect = state.canvasRect
        let plan = MotionBlurPlan(sourceTime: 0, shutterDuration: 0.01, displacement: 10,
                                  samples: [.init(sourceTime: 0, weight: 0.5), .init(sourceTime: 1, weight: 0.5)])
        let image = renderer.renderBlurred(plan: plan) { t in
            (Self.solidSource(t < 0.5 ? Self.red : Self.blue), state)
        }
        let p = try Pixels(image).at(160, 100)
        // Averaged in linear light: 0.5 → sRGB ≈ 188.
        #expect(abs(p.r - p.b) <= 3)
        #expect((180...196).contains(p.r))
        #expect(p.g < 5)
        #expect(p.a == 255)

        // One sample = plain render.
        let single = renderer.renderBlurred(plan: .single(sourceTime: 0)) { _ in (Self.solidSource(Self.red), state) }
        #expect(try Pixels(single).matches(160, 100, Self.red))
    }

    @Test func gradientBackgroundMatchesBackgroundRenderer() throws {
        var state = Self.state()
        state.background = .preset(GradientCatalog.defaultPresetID)
        let px = try Pixels(renderer.render(source: Self.quadrantSource(), state: state))
        let ctx = RenderSupport.makeBitmapContext(width: 320, height: 200)!
        RenderSupport.flipToTopLeft(ctx, height: 200)
        BackgroundRenderer.drawFill(state.background, in: CGRect(x: 0, y: 0, width: 320, height: 200), context: ctx)
        let ref = try #require(ctx.data).assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(3, 3), (316, 196), (10, 190)] {
            let i = y * ctx.bytesPerRow + x * 4
            let p = px.at(x, y)
            #expect(abs(p.r - Int(ref[i])) <= 3 && abs(p.g - Int(ref[i + 1])) <= 3 && abs(p.b - Int(ref[i + 2])) <= 3)
        }
    }
}
