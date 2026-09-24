import CoreGraphics
import Foundation
import ImageIO

public enum ImageEncoderError: Error, Sendable, Equatable {
    /// The running system's ImageIO can't write this format (see
    /// `ImageFormat.isSupported`).
    case unsupportedFormat(ImageFormat)
    case destinationCreationFailed
    case encodingFailed
}

/// Encode-time parameters. `compressionQuality` is ignored for PNG (lossless).
/// `dpi` is written as both `kCGImagePropertyDPIWidth`/`Height` so Preview,
/// Keynote, etc. open the file at its point size rather than its pixel size
/// (plan §4.7: 72 × scale, i.e. 144 for Retina 2x).
public struct ImageEncodeOptions: Sendable, Equatable {
    public var compressionQuality: CGFloat
    public var dpi: CGFloat

    public init(compressionQuality: CGFloat = 0.85, dpi: CGFloat = 72) {
        self.compressionQuality = compressionQuality
        self.dpi = dpi
    }

    /// The plan's §5.4 defaults for each format at a given backing scale:
    /// PNG quality is irrelevant (lossless), JPEG 0.85, HEIC 0.80, WebP 0.85.
    public static func defaults(for format: ImageFormat, scale: CGFloat) -> ImageEncodeOptions {
        let quality: CGFloat
        switch format {
        case .png: quality = 1.0
        case .jpeg: quality = 0.85
        case .heic: quality = 0.80
        case .webp: quality = 0.85
        }
        return ImageEncodeOptions(compressionQuality: quality, dpi: 72 * scale)
    }
}

/// Encodes/decodes raster images through ImageIO (plan §1.6). No AppKit —
/// works directly against `CGImage`/`Data` so it's usable from HakoKit tests.
public enum ImageEncoder {
    public static func encode(_ image: CGImage, format: ImageFormat, options: ImageEncodeOptions) throws -> Data {
        // WebP: ImageIO can decode it but this OS's `CGImageDestination`
        // can't write it (`ImageFormat.isSupported`, spiked in WP7.3), so
        // fall back to libwebp directly. No DPI metadata is written on this
        // path (libwebp's one-stop encode API has no metadata hook) — a
        // known gap vs. the ImageIO path below.
        if format == .webp, !format.isSupported {
            return try WebPEncoder.encode(image, quality: options.compressionQuality)
        }

        guard format.isSupported else {
            throw ImageEncoderError.unsupportedFormat(format)
        }

        let mutableData = CFDataCreateMutable(nil, 0)!
        guard let destination = CGImageDestinationCreateWithData(mutableData, format.utTypeIdentifier as CFString, 1, nil) else {
            throw ImageEncoderError.destinationCreationFailed
        }

        var properties: [String: Any] = [
            kCGImagePropertyDPIWidth as String: options.dpi,
            kCGImagePropertyDPIHeight as String: options.dpi,
        ]
        if format != .png {
            properties[kCGImageDestinationLossyCompressionQuality as String] = options.compressionQuality
        }

        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageEncoderError.encodingFailed
        }

        return mutableData as Data
    }

    /// Decodes the first image in `data`, for round-trip tests and general use.
    public static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Reads back the DPI metadata written by `encode(_:format:options:)`.
    public static func dpi(of data: Data) -> CGFloat? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpiWidth = properties[kCGImagePropertyDPIWidth] as? CGFloat
        else {
            return nil
        }
        return dpiWidth
    }
}
