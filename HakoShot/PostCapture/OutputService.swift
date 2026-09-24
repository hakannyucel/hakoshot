import CoreGraphics
import Foundation
import HakoKit

/// Errors `OutputService.save(_:)` can throw.
enum OutputServiceError: Error, Sendable {
    case folderCreationFailed(underlying: any Error)
    case encodingFailed(underlying: any Error)
    case writeFailed(underlying: any Error)
    /// "Scale Retina screenshots to 1x" is on but the downsampled bitmap
    /// context couldn't be created (plan §4.7).
    case retinaDownscaleFailed
}

/// Writes a finished `CaptureResult` to disk (plan §3.2 `OutputService`,
/// §1.6, §5.4): `FileNamer` for a collision-safe name, `ImageEncoder` for the
/// bytes, at 72 × `scale` DPI so the file opens at its point size. Reads
/// folder/format/template from `AppSettings` so callers only ever call
/// `save(_:)`; tests inject a scratch `AppSettings` (backed by a throwaway
/// `UserDefaults` suite) pointed at a temp directory instead of touching the
/// real `~/Desktop`.
final class OutputService {
    private let settings: AppSettings
    private let fileManager: FileManager

    init(settings: AppSettings, fileManager: FileManager = .default) {
        self.settings = settings
        self.fileManager = fileManager
    }

    /// Encodes and writes `result` under the configured save folder
    /// (creating it if missing) and returns the URL actually written.
    /// Never overwrites an existing file: the name is resolved via
    /// `FileNamer.resolvedURL` (appends " (2)", " (3)", …) and the write
    /// itself additionally uses `.withoutOverwriting` as defense-in-depth
    /// against a race between that check and the write.
    func save(_ result: CaptureResult) throws -> URL {
        let format = settings.value(for: .outputImageFormat)
        let folder = URL(
            fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath,
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw OutputServiceError.folderCreationFailed(underlying: error)
        }

        // "Scale Retina screenshots to 1x" (plan §4.7): downsample to the
        // capture's point size instead of writing native Retina pixels. Once
        // downsampled the file *is* 1x, so `effectiveScale` (used for both
        // the DPI metadata below and the "@2x" suffix decision) drops to 1
        // regardless of the source display's actual backing scale factor.
        let scalesToPointSize = settings.value(for: .outputScaleRetinaTo1x) && result.scale > 1
        let effectiveScale = scalesToPointSize ? 1 : result.scale
        let appendsRetinaSuffix = settings.value(for: .outputAppendsRetinaSuffix) && effectiveScale > 1

        let pattern = settings.value(for: .outputFileNameTemplate)
        let namer = FileNamer(
            template: FileNameTemplate(pattern: pattern),
            pathExtension: format.fileExtension,
            retinaSuffix: appendsRetinaSuffix ? Self.retinaSuffix(forScale: effectiveScale) : ""
        )
        // `%n`: running counter, advanced once per saved file (only when the pattern uses it).
        let counter = FileNameCounter.take(pattern: pattern, settings: settings)
        let url = namer.resolvedURL(in: folder, counter: counter, mode: result.mode.fileNameToken) { candidate in
            fileManager.fileExists(atPath: candidate.path)
        }

        let data: Data
        do {
            var image = result.image
            if scalesToPointSize {
                guard let downscaled = Self.downscaled(image, toPointSize: result.pointSize) else {
                    throw OutputServiceError.retinaDownscaleFailed
                }
                image = downscaled
            }
            if format == .jpeg {
                image = Self.flattenedOntoWhite(image)
            }
            let options = ImageEncodeOptions(
                compressionQuality: CGFloat(settings.outputQuality(for: format)),
                dpi: 72 * effectiveScale
            )
            data = try ImageEncoder.encode(image, format: format, options: options)
        } catch {
            throw OutputServiceError.encodingFailed(underlying: error)
        }

        do {
            try data.write(to: url, options: .withoutOverwriting)
        } catch {
            throw OutputServiceError.writeFailed(underlying: error)
        }

        return url
    }

    /// Downsamples `image` to `pointSize` pixels (its 1x / non-Retina pixel
    /// grid) with high-quality interpolation, for "Scale Retina screenshots
    /// to 1x" (plan §4.7). Mirrors `flattenedOntoWhite`'s colorspace/alpha
    /// handling so it works for both opaque and alpha-carrying captures
    /// (e.g. window captures with a transparent background).
    static func downscaled(_ image: CGImage, toPointSize pointSize: CGSize) -> CGImage? {
        let width = Int(pointSize.width.rounded())
        let height = Int(pointSize.height.rounded())
        guard width > 0, height > 0 else { return nil }

        let hasAlpha: Bool
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
        default: hasAlpha = true
        }
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: (hasAlpha ? CGImageAlphaInfo.premultipliedFirst.rawValue : CGImageAlphaInfo.noneSkipFirst.rawValue)
                      | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// `"@2x"`-style suffix for a given effective scale (plan §4.7 "@2x
    /// suffix"). Handles the practically-always-integral case (`2`, `3`)
    /// without assuming exactly 2x, in case a future display reports a
    /// non-2x `backingScaleFactor`.
    static func retinaSuffix(forScale scale: CGFloat) -> String {
        let rounded = scale.rounded()
        if abs(scale - rounded) < 0.001 {
            return "@\(Int(rounded))x"
        }
        return "@\(String(format: "%.2g", scale))x"
    }

    /// JPEG has no alpha channel: transparent pixels (window shadows,
    /// transparent window backgrounds) would otherwise turn black. Draws
    /// `image` over opaque white (plan §4.4). Opaque images pass through.
    static func flattenedOntoWhite(_ image: CGImage) -> CGImage {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        let colorSpace = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { return image }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
        return context.makeImage() ?? image
    }
}

/// The `%mode` file-name token (plan §5.4) for each `CaptureMode`. Lives here
/// rather than on `AppCommand.swift` (owned by another package) since Swift
/// extensions can live in any file in the module.
extension CaptureMode {
    var fileNameToken: String {
        switch self {
        case .area: return "area"
        case .window: return "window"
        case .fullscreen: return "fullscreen"
        case .previousArea: return "previous-area"
        case .scrolling: return "scrolling"
        case .selfTimer: return "self-timer"
        case .allInOne: return "all-in-one"
        case .text: return "text"
        }
    }
}
