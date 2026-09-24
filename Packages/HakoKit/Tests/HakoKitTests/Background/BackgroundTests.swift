import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("Background")
struct BackgroundTests {
    static let blue = RGBAColor(hex: "#0000FF") ?? .black
    static let red = RGBAColor(hex: "#FF0000") ?? .black

    /// 400×300 px canvas at 2× (so 10 pt padding = 20 px).
    static func document(_ style: BackgroundStyle?, width: Int = 400, height: Int = 300) -> ProjectDocument {
        var doc = RenderFixtures.document(width: width, height: height)
        doc.background = style
        return doc
    }

    /// Plain style: solid blue fill, no corners, no shadow, no balance.
    static func plain(
        padding: Double = 10, alignment: BackgroundAlignment = .center,
        ratio: BackgroundAspectRatio = .auto, corner: Double = 0, shadow: BackgroundShadow = .none
    ) -> BackgroundStyle {
        BackgroundStyle(fill: .solid(blue), padding: padding, inset: 0, autoBalance: false,
                        alignment: alignment, aspectRatio: ratio, cornerRadius: corner, shadow: shadow)
    }

    // MARK: Size

    @Test func paddingGrowsOutputByScaledPoints() throws {
        let doc = Self.document(Self.plain(padding: 10))
        #expect(DocumentRenderer.outputSize(of: doc) == CGSize(width: 440, height: 340))
        let renderer = RenderFixtures.renderer(base: RenderFixtures.solid(Self.red, width: 400, height: 300))
        let image = try #require(renderer.makeImage(doc))
        #expect(image.width == 440 && image.height == 340)
        #expect(renderer.outputLayout(of: doc).size == CGSize(width: 440, height: 340))
    }

    @Test(arguments: [
        (BackgroundAspectRatio.auto, CGSize(width: 440, height: 340)),
        (.square, CGSize(width: 440, height: 440)),
        (.fourThree, CGSize(width: 453, height: 340)),
        (.threeTwo, CGSize(width: 510, height: 340)),
        (.sixteenNine, CGSize(width: 604, height: 340)),
        (.ratio(width: 1, height: 2), CGSize(width: 440, height: 880)),
    ])
    func aspectRatioSizes(ratio: BackgroundAspectRatio, expected: CGSize) {
        let doc = Self.document(Self.plain(padding: 10, ratio: ratio))
        #expect(DocumentRenderer.outputSize(of: doc) == expected)
    }

    @Test func backgroundWrapsRotatedContent() {
        var doc = Self.document(Self.plain(padding: 10))
        doc.transform = CanvasTransform(rotationQuarterTurns: 1)
        #expect(DocumentRenderer.outputSize(of: doc) == CGSize(width: 340, height: 440))
        // Canvas top-left lands at the content's top-right after a clockwise turn.
        let p = CGPoint(x: 0, y: 0).applying(DocumentRenderer.outputTransform(of: doc))
        #expect(p == CGPoint(x: 320, y: 20))
    }

    @Test func noBackgroundKeepsContentSize() {
        let doc = Self.document(nil)
        #expect(DocumentRenderer.outputSize(of: doc) == CGSize(width: 400, height: 300))
        #expect(DocumentRenderer.outputTransform(of: doc) == .identity)
    }

    // MARK: Alignment

    @Test(arguments: [
        (BackgroundAlignment.topLeft, CGPoint(x: 0, y: 0)),
        (.top, CGPoint(x: 20, y: 0)),
        (.topRight, CGPoint(x: 40, y: 0)),
        (.left, CGPoint(x: 0, y: 70)),
        (.center, CGPoint(x: 20, y: 70)),
        (.right, CGPoint(x: 40, y: 70)),
        (.bottomLeft, CGPoint(x: 0, y: 140)),
        (.bottom, CGPoint(x: 20, y: 140)),
        (.bottomRight, CGPoint(x: 40, y: 140)),
    ])
    func alignmentPlacesContent(alignment: BackgroundAlignment, origin: CGPoint) throws {
        // 440×440 square canvas, 400×300 card: 40 px free horizontally, 140 vertically.
        let doc = Self.document(Self.plain(padding: 10, alignment: alignment, ratio: .square))
        #expect(CGPoint.zero.applying(DocumentRenderer.outputTransform(of: doc)) == origin)

        let renderer = RenderFixtures.renderer(base: RenderFixtures.solid(Self.red, width: 400, height: 300))
        let pixels = try #require(RenderFixtures.render(doc, with: renderer))
        let x = Int(origin.x), y = Int(origin.y)
        #expect(pixels.pixel(x + 1, y + 1).isClose(to: RGBA(Self.red)))
        #expect(pixels.pixel(x + 398, y + 298).isClose(to: RGBA(Self.red)))
        if x > 0 { #expect(pixels.pixel(x - 1, y + 150).isClose(to: RGBA(Self.blue))) }
        if y > 0 { #expect(pixels.pixel(x + 200, y - 1).isClose(to: RGBA(Self.blue))) }
        if x + 400 < 440 { #expect(pixels.pixel(x + 400, y + 150).isClose(to: RGBA(Self.blue))) }
        if y + 300 < 440 { #expect(pixels.pixel(x + 200, y + 300).isClose(to: RGBA(Self.blue))) }
    }

    @Test func flushEdgesKeepSquareCorners() {
        let layout = BackgroundLayout(contentSize: CGSize(width: 400, height: 300),
                                      style: Self.plain(padding: 10, alignment: .bottom, corner: 12), scale: 2)
        #expect(layout.flushEdges == [.bottom])
        #expect(layout.cardPath.contains(CGPoint(x: layout.cardRect.minX + 0.5, y: layout.cardRect.maxY - 0.5)))
        #expect(!layout.cardPath.contains(CGPoint(x: layout.cardRect.minX + 0.5, y: layout.cardRect.minY + 0.5)))
    }

    // MARK: Corners + shadow

    @Test func roundedCornersRevealBackground() throws {
        let doc = Self.document(Self.plain(padding: 10, corner: 20)) // 40 px radius
        let renderer = RenderFixtures.renderer(base: RenderFixtures.solid(Self.red, width: 400, height: 300))
        let pixels = try #require(RenderFixtures.render(doc, with: renderer))
        // Content spans (20, 20)–(420, 320).
        for (x, y) in [(21, 21), (418, 21), (21, 318), (418, 318)] {
            #expect(pixels.pixel(x, y).isClose(to: RGBA(Self.blue)), "corner \(x),\(y): \(pixels.pixel(x, y))")
        }
        #expect(pixels.pixel(220, 21).isClose(to: RGBA(Self.red)))
        #expect(pixels.pixel(21, 170).isClose(to: RGBA(Self.red)))
        #expect(pixels.pixel(220, 170).isClose(to: RGBA(Self.red)))
    }

    @Test func shadowDarkensBelowCard() throws {
        let white = RenderFixtures.solid(.white, width: 400, height: 300)
        let renderer = RenderFixtures.renderer(base: white)
        var style = Self.plain(padding: 30, shadow: .standard)
        style.fill = .solid(.white)
        let shadowed = try #require(RenderFixtures.render(Self.document(style), with: renderer))
        style.shadow = .none
        let flat = try #require(RenderFixtures.render(Self.document(style), with: renderer))
        // Content spans (60, 60)–(460, 360); look 12 px below it.
        let below = shadowed.pixel(260, 372)
        let above = shadowed.pixel(260, 50)
        #expect(below.luminance < 235, "below: \(below)")
        #expect(below.luminance < above.luminance - 10)
        #expect(flat.pixel(260, 372).isClose(to: .white))
    }

    // MARK: Inset + auto-balance

    /// White image with a black block: margins top 10, left 20, bottom 20, right 50.
    static func marginImage() -> CGImage? {
        guard let ctx = RenderSupport.makeBitmapContext(width: 200, height: 100) else { return nil }
        RenderSupport.flipToTopLeft(ctx, height: 100)
        ctx.setFillColor(RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        ctx.setFillColor(RGBAColor.black.cgColor)
        ctx.fill(CGRect(x: 20, y: 10, width: 130, height: 70))
        return ctx.makeImage()
    }

    @Test func autoBalanceMeasuresUniformMargins() throws {
        let image = try #require(Self.marginImage())
        let analysis = try #require(AutoBalance.analyze(image))
        #expect(analysis.isUniform)
        #expect(RGBA(analysis.edgeColor).isClose(to: .white))
        #expect(analysis.margins == BackgroundInsets(top: 10, left: 20, bottom: 20, right: 50))
        #expect(analysis.balancingInsets == BackgroundInsets(top: 10, left: 30, bottom: 0, right: 0))
    }

    @Test func autoBalanceIgnoresBusyEdges() throws {
        let image = try #require(RenderFixtures.pattern(width: 120, height: 80))
        let analysis = try #require(AutoBalance.analyze(image))
        #expect(!analysis.isUniform)
        #expect(analysis.balancingInsets == .zero)
    }

    @Test func autoBalanceAndInsetGrowCardWithEdgeColor() throws {
        let renderer = RenderFixtures.renderer(base: Self.marginImage())
        var style = Self.plain(padding: 10)
        style.autoBalance = true
        style.inset = 5 // 10 px
        let doc = Self.document(style, width: 200, height: 100)
        let layout = renderer.outputLayout(of: doc)
        // content 200×100 + inset 10 each side + balance (left 30, top 10) + padding 20 each side.
        #expect(layout.size == CGSize(width: 200 + 20 + 30 + 40, height: 100 + 20 + 10 + 40))
        #expect(CGPoint.zero.applying(layout.transform) == CGPoint(x: 20 + 10 + 30, y: 20 + 10 + 10))
        let pixels = try #require(RenderFixtures.render(doc, with: renderer))
        #expect(pixels.width == 290 && pixels.height == 170)
        // Inset / balance space is white (edge color), padding is blue.
        #expect(pixels.pixel(25, 85).isClose(to: .white))
        #expect(pixels.pixel(5, 85).isClose(to: RGBA(Self.blue)))
        // The black block: canvas (20, 10) → output (80, 50).
        #expect(pixels.pixel(81, 51).isClose(to: .black))
        // Balanced: white band left of the block == white band right of it (60 px each).
        #expect(pixels.pixel(81 - 60, 60).isClose(to: .white))
        #expect(pixels.pixel(80 + 130 + 59, 60).isClose(to: .white))
    }

    // MARK: Fills

    @Test(arguments: [
        BackgroundFill.preset("aurora"), .gradient(GradientSpec(colors: [.annotationPink, .annotationBlue])),
        .blurredScreenshot,
    ])
    func fillsCoverThePadding(fill: BackgroundFill) throws {
        var style = Self.plain(padding: 10)
        style.fill = fill
        let renderer = RenderFixtures.renderer(base: RenderFixtures.pattern(width: 400, height: 300))
        let pixels = try #require(RenderFixtures.render(Self.document(style), with: renderer))
        for (x, y) in [(2, 2), (437, 2), (2, 337), (437, 337)] {
            #expect(pixels.pixel(x, y).a == 255, "\(fill) at \(x),\(y)")
        }
    }

    @Test func transparentFillLeavesPaddingClear() throws {
        var style = Self.plain(padding: 10)
        style.fill = .transparent
        let renderer = RenderFixtures.renderer(base: RenderFixtures.solid(Self.red, width: 400, height: 300))
        let pixels = try #require(RenderFixtures.render(Self.document(style), with: renderer))
        #expect(pixels.pixel(2, 2).a == 0)
        #expect(pixels.pixel(220, 170).isClose(to: RGBA(Self.red)))
    }

    // MARK: Codable

    @Test(arguments: [
        BackgroundFill.preset("sunset"), .gradient(GradientSpec(stops: [.init(.white, at: 0), .init(.black, at: 1)], angle: 30,
                                                                  glows: [.init(.annotationPink, x: 0.2, y: 0.8, radius: 0.5)])),
        .solid(.annotationGreen), .image(AssetID(rawValue: "WALL")), .blurredScreenshot, .transparent,
    ])
    func styleRoundTrips(fill: BackgroundFill) throws {
        let style = BackgroundStyle(fill: fill, padding: 32, inset: 4, autoBalance: false, alignment: .bottomRight,
                                    aspectRatio: .ratio(width: 21, height: 9), cornerRadius: 8,
                                    shadow: BackgroundShadow(opacity: 0.3, radius: 10, offsetX: 2, offsetY: 6))
        let data = try JSONEncoder().encode(style)
        #expect(try JSONDecoder().decode(BackgroundStyle.self, from: data) == style)
    }

    @Test func documentRoundTripsBackground() throws {
        let doc = Self.document(.standard)
        let decoded = try ProjectDocument(jsonData: try doc.jsonData())
        #expect(decoded.background == .standard)
        #expect(decoded == doc)
    }

    @Test func missingFieldsUseDefaults() throws {
        let json = ##"{"fill": {"kind": "solid", "color": "#FF0000FF"}, "aspectRatio": "16:9", "futureField": 1}"##
        let style = try JSONDecoder().decode(BackgroundStyle.self, from: Data(json.utf8))
        var expected = BackgroundStyle.standard
        expected.fill = .solid(Self.red)
        expected.aspectRatio = .sixteenNine
        #expect(style == expected)
    }

    @Test func oldPlaceholderBackgroundDecodesToNil() throws {
        let json = """
        {"formatVersion": 1, "canvas": {"width": 10, "height": 10, "scale": 1}, "layers": [],
         "background": {"kind": "gradient", "padding": 64, "autoBalance": true,
                        "stops": ["#FF375FFF", "#0A84FFFF"], "image": null}}
        """
        let doc = try ProjectDocument(jsonData: Data(json.utf8))
        #expect(doc.background == nil)
        let weird = #"{"formatVersion": 1, "canvas": {"width": 10, "height": 10, "scale": 1}, "layers": [], "background": [1, "x"]}"#
        #expect(try ProjectDocument(jsonData: Data(weird.utf8)).background == nil)
    }

    @Test func aspectRatioLabels() {
        #expect(BackgroundAspectRatio(label: "16:9") == .sixteenNine)
        #expect(BackgroundAspectRatio(label: "Auto") == .auto)
        #expect(BackgroundAspectRatio(label: "1.5:1")?.value == 1.5)
        #expect(BackgroundAspectRatio(label: "0:1") == nil)
        #expect(BackgroundAspectRatio.threeTwo.label == "3:2")
    }

    // MARK: Catalog

    @Test func catalogIdsAreUniqueAndPlentiful() {
        let ids = GradientCatalog.gradients.map(\.id)
        #expect(ids.count >= 20)
        #expect(Set(ids).count == ids.count)
        #expect(GradientCatalog.preset(id: GradientCatalog.defaultPresetID) != nil)
        #expect(GradientCatalog.solidColors.count == 10)
        #expect(GradientCatalog.gradients.allSatisfy { $0.spec.stops.count >= 2 })
        #expect(GradientCatalog.spec(for: "no-such-preset") == GradientCatalog.gradients.first?.spec)
    }
}
