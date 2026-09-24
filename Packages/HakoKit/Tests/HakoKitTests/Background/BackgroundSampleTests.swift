import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HakoKit

/// Opt-in visual check: `HAKOSHOT_BACKGROUND_SAMPLE=/some/dir swift test
/// --filter BackgroundSample` writes the sample document on a few background
/// styles plus a contact sheet of every catalog gradient.
@Suite("BackgroundSample")
struct BackgroundSampleTests {
    static let outputDirectory = ProcessInfo.processInfo.environment["HAKOSHOT_BACKGROUND_SAMPLE"]

    static func write(_ image: CGImage, _ name: String) throws {
        let dir = try #require(outputDirectory)
        let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
        let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test(.enabled(if: outputDirectory != nil))
    func writeStyledSamples() throws {
        let scale = 1.0
        let base = SampleDocument.baseImage(scale: scale)
        var doc = RenderFixtures.document(width: 800, height: 600)
        doc.canvas.scale = scale
        doc.annotations = Array(SampleDocument.annotations(scale: scale).prefix(12))
        let renderer = RenderFixtures.renderer(base: base)
        let styles: [(String, BackgroundStyle)] = [
            ("bg-default.png", .standard),
            ("bg-bottom-169.png", BackgroundStyle(fill: .preset("sunset"), alignment: .bottom, aspectRatio: .sixteenNine)),
            ("bg-blur-square.png", BackgroundStyle(fill: .blurredScreenshot, padding: 48, aspectRatio: .square)),
            ("bg-inset-midnight.png", BackgroundStyle(fill: .preset("midnight"), inset: 24, cornerRadius: 16)),
        ]
        for (name, style) in styles {
            doc.background = style
            try Self.write(try #require(renderer.makeImage(doc)), name)
        }
    }

    @Test(.enabled(if: outputDirectory != nil))
    func writeGradientContactSheet() throws {
        let tile = 220.0, gap = 16.0, columns = 6
        let presets = GradientCatalog.gradients
        let rows = (presets.count + columns - 1) / columns + 1
        let width = Int(gap + Double(columns) * (tile + gap))
        let height = Int(gap + Double(rows) * (tile * 0.7 + gap))
        let ctx = try #require(RenderSupport.makeBitmapContext(width: width, height: height))
        RenderSupport.flipToTopLeft(ctx, height: CGFloat(height))
        ctx.setFillColor(RGBAColor(hex: "#ECECEC")?.cgColor ?? RGBAColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (i, preset) in presets.enumerated() {
            let rect = CGRect(x: gap + Double(i % columns) * (tile + gap), y: gap + Double(i / columns) * (tile * 0.7 + gap),
                              width: tile, height: tile * 0.7)
            ctx.saveGState()
            ctx.addPath(RenderSupport.roundedRectPath(rect, radius: 14))
            ctx.clip()
            BackgroundRenderer.drawFill(.preset(preset.id), in: rect, context: ctx)
            ctx.restoreGState()
        }
        let lastRow = Double(rows - 1)
        for (i, color) in GradientCatalog.solidColors.enumerated() {
            let d = 48.0
            let rect = CGRect(x: gap + Double(i) * (d + gap), y: gap + lastRow * (tile * 0.7 + gap), width: d, height: d)
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: rect)
        }
        try Self.write(try #require(ctx.makeImage()), "bg-catalog.png")
    }
}
