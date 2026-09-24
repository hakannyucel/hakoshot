import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How the encoder reduces frames to ≤ 256 colors (plan §1.7).
public enum GIFQuantization: Sendable, Hashable {
    /// Hand full-color frames to ImageIO and let it quantize each frame.
    case imageIO
    /// Map every frame to one global palette (median cut over sampled
    /// frames) with optional Floyd–Steinberg dithering. ImageIO then writes
    /// the indexed frames losslessly. At most `GIFExportOptions.maxColors`
    /// (255) colors: ImageIO reserves index 255 for transparency.
    case palette(GIFColorPalette, dither: Double)
    /// Build a median-cut palette per frame (no global palette available).
    case perFrame(maxColors: Int, dither: Double)

    /// The quantization for export `options`: a global palette from
    /// `sampleFrames` (plan: up to 32 frames) sized and dithered by
    /// `options.quality`; ImageIO's own when no samples are given.
    public static func forOptions(_ options: GIFExportOptions, sampleFrames: [RGBAPixelBuffer]) -> GIFQuantization {
        let o = options.normalized()
        guard !sampleFrames.isEmpty else { return .imageIO }
        let step = sampleFrames.count > 8 ? 2 : 1
        let palette = ColorQuantizer.palette(from: sampleFrames, maxColors: o.paletteColorCount, sampleStep: step)
        return .palette(palette, dither: o.ditherStrength)
    }
}

public enum GIFEncoderError: Error, Sendable, Equatable {
    case cannotCreateDestination
    case invalidFrame
    case paletteTooLarge(Int)
    case alreadyFinalized
    case noFrames
    case finalizeFailed
}

/// Streaming GIF writer over `CGImageDestination` (plan §1.7).
///
/// ```swift
/// let encoder = try GIFEncoder(url: url, loopCount: 0)
/// try encoder.add(frame: image, delayCentiseconds: 7)
/// try encoder.finalize()
/// ```
/// Frames are written as they arrive; the destination is created with an
/// unknown frame count, which ImageIO accepts. Not thread-safe: use one
/// encoder from one task.
public final class GIFEncoder {
    public let url: URL
    /// 0 = loop forever.
    public let loopCount: Int
    public let quantization: GIFQuantization
    public private(set) var frameCount = 0
    public private(set) var totalDelayCentiseconds = 0
    public private(set) var isFinalized = false

    private let destination: CGImageDestination
    private var mapper: PaletteMapper?
    private let dither: Double

    public init(url: URL, loopCount: Int = 0, quantization: GIFQuantization = .imageIO) throws(GIFEncoderError) {
        switch quantization {
        case let .palette(palette, dither):
            guard palette.count <= GIFExportOptions.maxColors else {
                throw .paletteTooLarge(palette.count)
            }
            mapper = PaletteMapper(palette: palette)
            self.dither = dither
        case let .perFrame(_, dither):
            self.dither = dither
        case .imageIO:
            self.dither = 0
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.gif.identifier as CFString, 0, nil
        ) else { throw .cannotCreateDestination }
        self.url = url
        self.loopCount = max(0, loopCount)
        self.quantization = quantization
        self.destination = destination
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: self.loopCount],
        ] as CFDictionary)
    }

    /// Appends one frame shown for `delayCentiseconds` (≥ 1) hundredths of
    /// a second.
    public func add(frame: CGImage, delayCentiseconds: Int) throws(GIFEncoderError) {
        guard !isFinalized else { throw .alreadyFinalized }
        let image: CGImage
        switch quantization {
        case .imageIO:
            image = frame
        case .palette, .perFrame:
            guard let buffer = RGBAPixelBuffer(cgImage: frame) else { throw .invalidFrame }
            image = try indexedImage(for: buffer)
        }
        write(image, delayCentiseconds: delayCentiseconds)
    }

    /// Appends one frame from an RGBA buffer (skips a CGImage round trip
    /// when quantizing).
    public func add(buffer: RGBAPixelBuffer, delayCentiseconds: Int) throws(GIFEncoderError) {
        guard !isFinalized else { throw .alreadyFinalized }
        let image: CGImage?
        switch quantization {
        case .imageIO:
            image = buffer.makeCGImage()
        case .palette, .perFrame:
            image = try indexedImage(for: buffer)
        }
        guard let image else { throw .invalidFrame }
        write(image, delayCentiseconds: delayCentiseconds)
    }

    /// Writes the file. Throws `.noFrames` for an empty GIF.
    public func finalize() throws(GIFEncoderError) {
        guard !isFinalized else { throw .alreadyFinalized }
        isFinalized = true
        guard frameCount > 0 else { throw .noFrames }
        guard CGImageDestinationFinalize(destination) else { throw .finalizeFailed }
    }

    /// Abandons the encode and removes any file at `url`.
    public func discard() {
        isFinalized = true
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Private

    private func indexedImage(for buffer: RGBAPixelBuffer) throws(GIFEncoderError) -> CGImage {
        guard buffer.width > 0, buffer.height > 0 else { throw .invalidFrame }
        var frameMapper: PaletteMapper
        let isGlobal: Bool
        if let mapper {
            frameMapper = mapper
            self.mapper = nil // unique owner, so the cache mutates in place
            isGlobal = true
        } else if case let .perFrame(maxColors, _) = quantization {
            let limit = min(max(maxColors, 1), GIFExportOptions.maxColors)
            frameMapper = PaletteMapper(palette: ColorQuantizer.palette(from: buffer, maxColors: limit))
            isGlobal = false
        } else {
            throw .invalidFrame
        }
        let indices = frameMapper.indices(for: buffer, dither: dither)
        if isGlobal { mapper = frameMapper } // keep the warmed cache
        guard let image = frameMapper.palette.makeIndexedImage(
            indices: indices, width: buffer.width, height: buffer.height
        ) else { throw .invalidFrame }
        return image
    }

    private func write(_ image: CGImage, delayCentiseconds: Int) {
        let delay = max(1, delayCentiseconds)
        let seconds = Double(delay) / 100
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: seconds,
                kCGImagePropertyGIFUnclampedDelayTime: seconds,
            ],
        ] as CFDictionary)
        frameCount += 1
        totalDelayCentiseconds += delay
    }
}
