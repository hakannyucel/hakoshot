import AppKit
import CoreGraphics
import HakoKit
import SwiftUI

/// Panel swatch images drawn with the export code (`BackgroundRenderer.drawFill`),
/// cached per fill + size.
@MainActor
enum BackgroundSwatchRenderer {
    private struct Key: Hashable {
        var fill: BackgroundFill
        var pixels: Int
        var image: ObjectIdentifier?
    }

    private static var cache: [Key: CGImage] = [:]

    /// Square swatch, `pixels` wide. `image` feeds `.image` / blurred fills.
    static func image(for fill: BackgroundFill, pixels: Int, image: CGImage? = nil) -> CGImage? {
        let key = Key(fill: fill, pixels: pixels, image: image.map(ObjectIdentifier.init))
        if let hit = cache[key] { return hit }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // y-down, as BackgroundRenderer expects.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        switch fill {
        case .blurredScreenshot:
            let blurred = image.flatMap { BackgroundRenderer.makeBlurredBackdrop(from: $0, size: rect.size) }
            BackgroundRenderer.drawFill(fill, in: rect, context: context, blurredScreenshot: blurred)
        case .image:
            BackgroundRenderer.drawFill(fill, in: rect, context: context, images: { _ in image })
        default:
            BackgroundRenderer.drawFill(fill, in: rect, context: context)
        }
        let result = context.makeImage()
        if cache.count > 200 { cache.removeAll() }
        cache[key] = result
        return result
    }
}

/// A rounded square swatch (report §9.3: ~64 px, 10–12 px corners, blue ring
/// outside the card when selected).
struct BackgroundSwatch: View {
    let fill: BackgroundFill
    var image: CGImage?
    var isSelected: Bool
    var help: String
    let action: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Button(action: action) {
                swatchImage(side: proxy.size.width)
                    .clipShape(RoundedRectangle(cornerRadius: EditorMetrics.backgroundSwatchRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: EditorMetrics.backgroundSwatchRadius, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
                    .padding(EditorMetrics.backgroundSelectionRing + 1.5)
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: EditorMetrics.backgroundSwatchRadius + 3.5, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: EditorMetrics.backgroundSelectionRing)
                        }
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .aspectRatio(1, contentMode: .fit)
        .help(help)
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private func swatchImage(side: CGFloat) -> some View {
        if fill == .transparent {
            CheckerboardView()
        } else if let cg = BackgroundSwatchRenderer.image(for: fill, pixels: max(Int(side * 2), 8), image: image) {
            Image(decorative: cg, scale: 2).resizable()
        } else {
            Color.gray.opacity(0.2)
        }
    }
}

/// Transparent swatch.
struct CheckerboardView: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white))
            for row in 0..<Int((size.height / cell).rounded(.up)) {
                for column in 0..<Int((size.width / cell).rounded(.up)) where (row + column) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell)),
                                 with: .color(Color(white: 0.85)))
                }
            }
        }
    }
}
