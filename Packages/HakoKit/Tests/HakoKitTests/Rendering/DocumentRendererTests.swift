import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("Renderer: shapes")
struct RendererShapeTests {
    let red = RGBA(.annotationRed)

    @Test func rectangleEdgeHasStrokeColorAndInteriorIsUntouched() throws {
        let rect = Annotation(kind: .rectangle(RectShape(rect: CGRect(x: 50, y: 50, width: 200, height: 100))),
                              style: RenderFixtures.noShadow())
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [rect]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(50, 100).isClose(to: red))     // left edge (stroke centered)
        #expect(px.pixel(150, 50).isClose(to: red))     // top edge
        #expect(px.pixel(248, 148).isClose(to: red))    // inside the stroke near bottom-right
        #expect(px.pixel(150, 100).isClose(to: .white)) // interior
        #expect(px.pixel(30, 30).isClose(to: .white))   // outside
    }

    @Test func rectangleOptionalFill() throws {
        var style = RenderFixtures.noShadow()
        style.fill = .annotationBlue
        let rect = Annotation(kind: .rectangle(RectShape(rect: CGRect(x: 50, y: 50, width: 200, height: 100))), style: style)
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [rect]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(150, 100).isClose(to: RGBA(.annotationBlue)))
        #expect(px.pixel(50, 100).isClose(to: red))
    }

    @Test func filledRectangleInterior() throws {
        let rect = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 100, y: 100, width: 80, height: 60))),
                              style: RenderFixtures.noShadow(.annotationGreen))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [rect]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(140, 130).isClose(to: RGBA(.annotationGreen)))
        #expect(px.pixel(102, 102).isClose(to: RGBA(.annotationGreen)))
        #expect(px.pixel(95, 95).isClose(to: .white))
    }

    @Test func ellipseStrokesTheEllipseNotTheCorners() throws {
        let ellipse = Annotation(kind: .ellipse(RectShape(rect: CGRect(x: 100, y: 50, width: 200, height: 200))),
                                 style: RenderFixtures.noShadow())
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [ellipse]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(200, 150).isClose(to: .white))  // center
        #expect(px.pixel(102, 102).isClose(to: .white))  // bounding-box corner
        #expect(px.pixel(100, 150).isClose(to: red))     // leftmost point of the ellipse
        #expect(px.pixel(200, 50).isClose(to: red))      // top
    }

    @Test func lineHasRoundCaps() throws {
        let line = Annotation(kind: .line(LineShape(start: CGPoint(x: 50, y: 100), end: CGPoint(x: 250, y: 100))),
                              style: RenderFixtures.noShadow(width: 20))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [line]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(150, 100).isClose(to: red))
        #expect(px.pixel(44, 100).isClose(to: red))      // cap extends past start
        #expect(px.pixel(150, 120).isClose(to: .white))
    }

    @Test(arguments: ArrowStyle.allCases)
    func arrowHeadCoversTheTip(style: ArrowStyle) throws {
        let arrow = Annotation(
            kind: .arrow(ArrowShape(start: CGPoint(x: 40, y: 150), end: CGPoint(x: 340, y: 150), arrowStyle: style)),
            style: RenderFixtures.noShadow(width: 8))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [arrow]),
                                                    with: RenderFixtures.whiteRenderer()))
        let head = ArrowShape.headLength(strokeWidth: 8)       // 32
        let half = ArrowShape.headHalfWidth(strokeWidth: 8)     // 16
        if style == .curved {
            // Head is oriented along the end tangent; its interior is still red.
            #expect(px.pixel(334, 150).isClose(to: red, tolerance: 40) || px.pixel(330, 149).isClose(to: red, tolerance: 40))
        } else {
            #expect(px.pixel(334, 150).isClose(to: red))       // just behind the tip
            // Near the head base, wider than the shaft.
            #expect(px.pixel(340 - Int(head) + 3, 150 + Int(half) - 4).isClose(to: red))
            #expect(px.pixel(340 - Int(head) + 3, 150 + Int(half) + 4).isClose(to: .white))
        }
        #expect(px.pixel(346, 150).isClose(to: .white))        // past the tip
        if style == .doubleHeaded {
            #expect(px.pixel(40 + Int(head) - 3, 150 + Int(half) - 4).isClose(to: red))
        }
    }

    @Test func thickArrowTapers() throws {
        let arrow = Annotation(
            kind: .arrow(ArrowShape(start: CGPoint(x: 40, y: 150), end: CGPoint(x: 340, y: 150), arrowStyle: .thick)),
            style: RenderFixtures.noShadow(width: 12))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [arrow]),
                                                    with: RenderFixtures.whiteRenderer()))
        // Near the tail the body is ~3 px half-width; near the head base ~12 px.
        #expect(px.pixel(60, 157).isClose(to: .white))
        #expect(px.pixel(280, 158).isClose(to: red))
    }

    @Test func pencilAndDot() throws {
        let pencil = Annotation(kind: .pencil(PathShape(points: [CGPoint(x: 50, y: 50), CGPoint(x: 150, y: 80), CGPoint(x: 250, y: 50)])),
                                style: RenderFixtures.noShadow(width: 10))
        let dot = Annotation(kind: .pencil(PathShape(points: [CGPoint(x: 300, y: 200)])), style: RenderFixtures.noShadow(width: 20))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [pencil, dot]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(50, 50).isClose(to: red))
        #expect(px.pixel(250, 50).isClose(to: red))
        #expect(px.pixel(300, 200).isClose(to: red))
        #expect(px.pixel(300, 215).isClose(to: .white))
    }

    @Test func highlighterMultipliesOverContent() throws {
        // Left half white, right half black.
        let base = try #require(RenderSupport.makeBitmapContext(width: 400, height: 300))
        base.setFillColor(RGBAColor.white.cgColor)
        base.fill(CGRect(x: 0, y: 0, width: 200, height: 300))
        base.setFillColor(RGBAColor.black.cgColor)
        base.fill(CGRect(x: 200, y: 0, width: 200, height: 300))
        let image = try #require(base.makeImage())
        let hl = Annotation(kind: .highlighter(PathShape(points: [CGPoint(x: 20, y: 150), CGPoint(x: 380, y: 150)])),
                            style: AnnotationStyle(color: .highlighterYellow, strokeWidth: 40, opacity: 1, shadow: false))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [hl]),
                                                    with: RenderFixtures.renderer(base: image)))
        #expect(px.pixel(100, 150).isClose(to: RGBA(.highlighterYellow)))
        #expect(px.pixel(300, 150).isClose(to: .black))   // multiply keeps black text black
    }

    @Test func counterBadgeHasFillAndDigit() throws {
        let counter = Annotation(kind: .counter(CounterShape(center: CGPoint(x: 200, y: 150), number: 7, diameter: 60)),
                                 style: RenderFixtures.noShadow(.annotationPink))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [counter]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(178, 150).isClose(to: RGBA(.annotationPink)))  // inside circle, left of the digit
        #expect(px.pixel(200, 115).isClose(to: .white))                   // above the circle
        var whiteInside = 0
        for y in 135...165 { for x in 185...215 where px.pixel(x, y).isClose(to: .white, tolerance: 30) { whiteInside += 1 } }
        #expect(whiteInside > 30) // the white digit
    }

    @Test func imageAnnotationIsDrawnScaledIntoFrame() throws {
        let extra = RenderFixtures.solid(.annotationBlue, width: 10, height: 10)
        let image = Annotation(kind: .image(ImageShape(assetID: RenderFixtures.extra, frame: CGRect(x: 100, y: 100, width: 50, height: 40))),
                               style: RenderFixtures.noShadow())
        let renderer = RenderFixtures.renderer(base: RenderFixtures.solid(.white, width: 400, height: 300), extra: extra)
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [image]), with: renderer))
        #expect(px.pixel(125, 120).isClose(to: RGBA(.annotationBlue)))
        #expect(px.pixel(160, 120).isClose(to: .white))
    }

    @Test func shadowDarkensBelowShape() throws {
        let rect = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 100, y: 100, width: 100, height: 50))),
                              style: AnnotationStyle(color: .annotationRed, strokeWidth: 10, shadow: true))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [rect]),
                                                    with: RenderFixtures.whiteRenderer()))
        // Shadow offset is downward (2 pt × scale 2).
        let below = px.pixel(150, 153)
        let above = px.pixel(150, 97)
        #expect(below.luminance < 250)
        #expect(below.luminance < above.luminance)
    }

    @Test func opacityBlendsWithBackground() throws {
        let rect = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 100, y: 100, width: 100, height: 50))),
                              style: AnnotationStyle(color: .black, strokeWidth: 10, opacity: 0.5, shadow: false))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [rect]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(150, 125).isClose(to: RGBA(r: 128, g: 128, b: 128), tolerance: 4))
    }
}

@Suite("Renderer: text")
struct RendererTextTests {
    @Test(arguments: TextStyle.allCases)
    func textRendersInsideItsBox(style: TextStyle) throws {
        let frame = CGRect(x: 40, y: 60, width: 300, height: 60)
        let text = Annotation(kind: .text(TextShape(text: "Hello", frame: frame, fontSize: 48, textStyle: style)),
                              style: RenderFixtures.noShadow(.annotationBlue))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [text]),
                                                    with: RenderFixtures.whiteRenderer()))
        var colored = 0
        for y in Int(frame.minY)..<Int(frame.maxY) {
            for x in Int(frame.minX)..<Int(frame.maxX) where !px.pixel(x, y).isClose(to: .white, tolerance: 10) {
                colored += 1
            }
        }
        #expect(colored > 300)
        // Nothing far to the right of the text ("Hello" at 48 px is < 200 px wide).
        #expect(px.pixel(330, 90).isClose(to: .white))
        if style.isBoxed {
            // Box fill just inside the padded box, left of the first glyph.
            #expect(px.pixel(Int(frame.minX) - 8, 90).isClose(to: RGBA(.annotationBlue)))
        }
    }

    @Test func textWrapsToFrameWidth() {
        let narrow = TextShape(text: "one two three four five", frame: CGRect(x: 0, y: 0, width: 120, height: 10), fontSize: 30)
        let wide = TextShape(text: "one two three four five", frame: CGRect(x: 0, y: 0, width: 2000, height: 10), fontSize: 30)
        let narrowHeight = TextLayout.fittedHeight(for: narrow)
        let wideHeight = TextLayout.fittedHeight(for: wide)
        #expect(narrowHeight > wideHeight * 2)
        #expect(TextLayout(shape: narrow).usedRect.width <= 120.5)
    }

    @Test func alignmentMovesLines() {
        let left = TextLayout(shape: TextShape(text: "Hi", frame: CGRect(x: 0, y: 0, width: 400, height: 40), fontSize: 30, alignment: .left))
        let right = TextLayout(shape: TextShape(text: "Hi", frame: CGRect(x: 0, y: 0, width: 400, height: 40), fontSize: 30, alignment: .right))
        #expect(left.usedRect.minX == 0)
        #expect(abs(right.usedRect.maxX - 400) < 0.5)
    }
}

@Suite("Renderer: redaction & spotlight")
struct RendererEffectTests {
    let region = CGRect(x: 96, y: 60, width: 144, height: 96)

    func redaction(_ method: RedactionMethod, strength: Double = 12, seed: UInt32 = 42) -> Annotation {
        Annotation(kind: .redaction(RedactionShape(rect: region, method: method, strength: strength, seed: seed)),
                   style: AnnotationStyle(color: .black, shadow: false))
    }

    @Test func pixelateMakesConstantBlocksThatDifferFromSource() throws {
        let source = try #require(RenderFixtures.pattern(width: 400, height: 300))
        let renderer = RenderFixtures.renderer(base: source)
        let original = try #require(PixelBuffer(source))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [redaction(.pixelate)]), with: renderer))
        // Every 12×12 block (anchored at the region's top-left) is one color.
        for by in stride(from: Int(region.minY), to: Int(region.maxY), by: 12) {
            for bx in stride(from: Int(region.minX), to: Int(region.maxX), by: 12) {
                let first = px.pixel(bx, by)
                for (dx, dy) in [(11, 0), (0, 11), (11, 11), (5, 6)] {
                    #expect(px.pixel(bx + dx, by + dy) == first)
                }
            }
        }
        var differing = 0
        for y in Int(region.minY)..<Int(region.maxY) {
            for x in Int(region.minX)..<Int(region.maxX) where px.pixel(x, y) != original.pixel(x, y) { differing += 1 }
        }
        #expect(differing > Int(region.width * region.height) / 2)
        // Outside is untouched.
        #expect(px.pixel(50, 50) == original.pixel(50, 50))
        #expect(px.pixel(Int(region.maxX) + 1, 100) == original.pixel(Int(region.maxX) + 1, 100))
    }

    @Test func pixelateIsRandomizedPerSeed() throws {
        let source = try #require(RenderFixtures.pattern(width: 400, height: 300))
        let renderer = RenderFixtures.renderer(base: source)
        let a = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [redaction(.pixelate, seed: 1)]), with: renderer))
        let b = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [redaction(.pixelate, seed: 2)]), with: renderer))
        #expect(a.bytes != b.bytes)
        // Jitter never exceeds ±6 % (+1 for rounding).
        for y in stride(from: Int(region.minY), to: Int(region.maxY), by: 12) {
            for x in stride(from: Int(region.minX), to: Int(region.maxX), by: 12) {
                let pa = a.pixel(x, y), pb = b.pixel(x, y)
                let maxChannel = Double(max(pa.r, pa.g, pa.b, pb.r, pb.g, pb.b))
                #expect(Double(abs(pa.r - pb.r)) <= maxChannel * 0.13 + 2)
            }
        }
    }

    @Test func redactionIgnoresShapesDrawnAboveIt() throws {
        // A shape overlapping the region must not bleed into the pixelation.
        let source = try #require(RenderFixtures.solid(.white, width: 400, height: 300))
        let blob = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 200, y: 60, width: 200, height: 200))),
                              style: RenderFixtures.noShadow(.black))
        let px = try #require(RenderFixtures.render(
            RenderFixtures.document(annotations: [blob, redaction(.pixelate)]), with: RenderFixtures.renderer(base: source)))
        // Block at the region's left edge is white-ish (jitter only), and the
        // black shape is still drawn on top of the redaction.
        #expect(px.pixel(100, 64).luminance > 230)
        #expect(px.pixel(220, 100).isClose(to: .black))
    }

    @Test func secureBlurAndSmoothBlurChangeTheRegion() throws {
        let source = try #require(RenderFixtures.pattern(width: 400, height: 300))
        let renderer = RenderFixtures.renderer(base: source)
        let original = try #require(PixelBuffer(source))
        for method in [RedactionMethod.secureBlur, .smoothBlur] {
            let px = try #require(RenderFixtures.render(
                RenderFixtures.document(annotations: [redaction(method, strength: 10)]), with: renderer))
            var differing = 0
            for y in Int(region.minY)..<Int(region.maxY) {
                for x in Int(region.minX)..<Int(region.maxX) where !px.pixel(x, y).isClose(to: original.pixel(x, y), tolerance: 8) {
                    differing += 1
                }
            }
            #expect(differing > Int(region.width * region.height) / 3, "\(method)")
            // Edges stay opaque (input clamped to extent).
            #expect(px.pixel(Int(region.minX), Int(region.minY)).a == 255)
        }
        let secure = try #require(RenderFixtures.render(
            RenderFixtures.document(annotations: [redaction(.secureBlur, strength: 10)]), with: renderer))
        let x0 = Int(region.minX), y0 = Int(region.minY)
        #expect(secure.pixel(x0, y0) == secure.pixel(x0 + 3, y0 + 3)) // 4 px blocks
    }

    @Test func blackOutIsBlack() throws {
        let renderer = RenderFixtures.renderer(base: RenderFixtures.pattern(width: 400, height: 300))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [redaction(.blackOut)]), with: renderer))
        #expect(px.pixel(Int(region.midX), Int(region.midY)) == .black)
        #expect(px.pixel(Int(region.minX), Int(region.minY)) == .black)
        #expect(px.pixel(Int(region.maxX) - 1, Int(region.maxY) - 1) == .black)
    }

    @Test func spotlightDimsOutsideOnly() throws {
        let spot = Annotation(kind: .spotlight(SpotlightShape(rect: CGRect(x: 100, y: 100, width: 100, height: 80), cornerRadius: 8, dimOpacity: 0.6)),
                              style: AnnotationStyle(shadow: false))
        let spot2 = Annotation(kind: .spotlight(SpotlightShape(rect: CGRect(x: 150, y: 150, width: 100, height: 80), cornerRadius: 0, dimOpacity: 0.4, isEllipse: true)),
                               style: AnnotationStyle(shadow: false))
        let px = try #require(RenderFixtures.render(RenderFixtures.document(annotations: [spot, spot2]),
                                                    with: RenderFixtures.whiteRenderer()))
        #expect(px.pixel(150, 140) == .white)                 // inside first hole
        #expect(px.pixel(190, 175) == .white)                 // overlap of both holes stays clear
        #expect(px.pixel(200, 190) == .white)                 // inside second (ellipse) hole
        #expect(px.pixel(20, 20).isClose(to: RGBA(r: 102, g: 102, b: 102), tolerance: 3)) // 60 % dim (max)
        #expect(px.pixel(152, 152).isClose(to: .white))
        #expect(px.pixel(102, 102).luminance < 255)           // rounded corner is dimmed
    }

    @Test func cacheHoldsOneEntryPerRedactionAndPrunes() throws {
        let cache = RedactionCache()
        let renderer = RenderFixtures.renderer(base: RenderFixtures.pattern(width: 400, height: 300), cache: cache)
        var doc = RenderFixtures.document(annotations: [redaction(.pixelate), redaction(.smoothBlur, seed: 9)])
        _ = renderer.makeImage(doc)
        #expect(cache.count == 2)
        // Moving an unrelated shape keeps the entries.
        doc.annotations.append(Annotation(kind: .line(LineShape(start: .zero, end: CGPoint(x: 10, y: 10))), style: AnnotationStyle()))
        _ = renderer.makeImage(doc)
        #expect(cache.count == 2)
        doc.annotations.removeFirst()
        _ = renderer.makeImage(doc)
        #expect(cache.count == 1)
    }
}

@Suite("Renderer: output")
struct RendererOutputTests {
    /// 400×300 white image with a red 10×10 marker at the top-left of the crop.
    func markedDocument() -> (ProjectDocument, DocumentRenderer) {
        let marker = Annotation(kind: .filledRectangle(RectShape(rect: CGRect(x: 50, y: 40, width: 10, height: 10))),
                                style: RenderFixtures.noShadow(.annotationRed))
        var doc = RenderFixtures.document(annotations: [marker])
        doc.crop = CGRect(x: 50, y: 40, width: 200, height: 100)
        return (doc, RenderFixtures.whiteRenderer())
    }

    @Test func exportAppliesCrop() throws {
        let (doc, renderer) = markedDocument()
        let image = try #require(renderer.makeImage(doc))
        #expect(image.width == 200)
        #expect(image.height == 100)
        let px = try #require(PixelBuffer(image))
        #expect(px.pixel(2, 2).isClose(to: RGBA(.annotationRed)))
        #expect(px.pixel(20, 20) == .white)
    }

    @Test(arguments: [
        (1, false, false, (97, 2)),       // 90° cw: top-left → top-right
        (2, false, false, (197, 97)),     // 180°: → bottom-right
        (3, false, false, (2, 197)),      // 270° cw: → bottom-left
        (0, true, false, (197, 2)),       // flip H
        (0, false, true, (2, 97)),        // flip V
        (1, true, false, (2, 2)),         // rotate then flip H
    ])
    func rotateAndFlip(turns: Int, flipH: Bool, flipV: Bool, marker: (Int, Int)) throws {
        var (doc, renderer) = markedDocument()
        doc.transform = CanvasTransform(rotationQuarterTurns: turns, flipHorizontal: flipH, flipVertical: flipV)
        let image = try #require(renderer.makeImage(doc))
        let size = DocumentRenderer.outputSize(of: doc)
        #expect(image.width == Int(size.width))
        #expect(image.height == Int(size.height))
        #expect(turns % 2 == 1 ? (image.width == 100 && image.height == 200) : (image.width == 200 && image.height == 100))
        let px = try #require(PixelBuffer(image))
        #expect(px.pixel(marker.0, marker.1).isClose(to: RGBA(.annotationRed)), "marker at \(marker)")
        // The transform maps the marker's canvas center to the same place.
        let mapped = CGPoint(x: 55, y: 45).applying(DocumentRenderer.outputTransform(of: doc))
        #expect(px.pixel(Int(mapped.x), Int(mapped.y)).isClose(to: RGBA(.annotationRed)))
    }

    @Test func renderingIsDeterministic() throws {
        var doc = RenderFixtures.document(width: 800, height: 600, annotations: SampleDocument.annotations(scale: 1))
        doc.crop = CGRect(x: 0, y: 0, width: 800, height: 600)
        let base = RenderFixtures.pattern(width: 800, height: 600)
        let a = try #require(RenderFixtures.render(doc, with: RenderFixtures.renderer(base: base)))
        let b = try #require(RenderFixtures.render(doc, with: RenderFixtures.renderer(base: base)))
        #expect(a.bytes == b.bytes)
    }

    @Test func canvasDrawWithDirtyRectMatchesFullRender() throws {
        let doc = RenderFixtures.document(width: 800, height: 600, annotations: SampleDocument.annotations(scale: 1))
        let renderer = RenderFixtures.renderer(base: RenderFixtures.pattern(width: 800, height: 600))
        let full = try #require(RenderFixtures.render(doc, with: renderer))
        let ctx = try #require(RenderSupport.makeBitmapContext(width: 800, height: 600))
        RenderSupport.flipToTopLeft(ctx, height: 600)
        let dirty = CGRect(x: 100, y: 100, width: 300, height: 250)
        renderer.drawCanvas(doc, in: ctx, options: .init(dirtyRect: dirty))
        let partial = try #require(ctx.makeImage().flatMap(PixelBuffer.init))
        for (x, y) in [(150, 150), (390, 340), (250, 200), (120, 330)] {
            #expect(partial.pixel(x, y).isClose(to: full.pixel(x, y), tolerance: 2), "(\(x), \(y))")
        }
        #expect(partial.pixel(500, 500).a == 0) // outside the dirty rect: nothing drawn
    }

    @Test func missingAssetDrawsTransparentBase() throws {
        let renderer = RenderFixtures.renderer(base: nil)
        let px = try #require(RenderFixtures.render(RenderFixtures.document(), with: renderer))
        #expect(px.pixel(10, 10).a == 0)
    }
}
