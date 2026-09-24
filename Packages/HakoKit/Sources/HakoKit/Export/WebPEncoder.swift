import Accelerate
import CoreGraphics
import libwebp

/// Errors from `WebPEncoder.encode(_:quality:)`.
enum WebPEncoderError: Error, Sendable, Equatable {
    case bitmapContextCreationFailed
    case unpremultiplyFailed
    case encodingFailed
}

/// Encodes a `CGImage` to WebP via libwebp directly (plan §1.6 WebP
/// fallback). ImageIO on this OS can *decode* WebP but not *write* it (see
/// `ImageFormat.isSupported`, spiked in WP7.3), so this bypasses
/// `CGImageDestination` entirely and calls libwebp's one-stop `WebPEncodeRGBA`
/// (lossy, `quality_factor` 0...100).
///
/// libwebp's RGBA input is *straight* (non-premultiplied) alpha, matching
/// PNG/TIFF convention, but `CGContext` can only render into premultiplied
/// (or opaque) buffers — so this draws into a premultiplied RGBA8 buffer and
/// then unpremultiplies with vImage before handing the bytes to libwebp.
enum WebPEncoder {
    /// - Parameter quality: 0...1, matching `ImageEncodeOptions.compressionQuality`.
    static func encode(_ image: CGImage, quality: CGFloat) throws -> Data {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { throw WebPEncoderError.encodingFailed }
        let bytesPerRow = width * 4

        var premultiplied = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context: CGContext? = premultiplied.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }
        guard let context else { throw WebPEncoderError.bitmapContextCreationFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var straight = [UInt8](repeating: 0, count: bytesPerRow * height)
        let unpremultiplyError = premultiplied.withUnsafeMutableBytes { src -> vImage_Error in
            straight.withUnsafeMutableBytes { dst -> vImage_Error in
                var srcBuffer = vImage_Buffer(
                    data: src.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                var dstBuffer = vImage_Buffer(
                    data: dst.baseAddress,
                    height: vImagePixelCount(height),
                    width: vImagePixelCount(width),
                    rowBytes: bytesPerRow
                )
                return vImageUnpremultiplyData_RGBA8888(&srcBuffer, &dstBuffer, 0)
            }
        }
        guard unpremultiplyError == kvImageNoError else { throw WebPEncoderError.unpremultiplyFailed }

        let qualityFactor = Float(max(0, min(1, quality)) * 100)
        var outputPointer: UnsafeMutablePointer<UInt8>?
        let size = straight.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return WebPEncodeRGBA(base, Int32(width), Int32(height), Int32(bytesPerRow), qualityFactor, &outputPointer)
        }
        guard size > 0, let outputPointer else { throw WebPEncoderError.encodingFailed }
        defer { WebPFree(outputPointer) }
        return Data(bytes: outputPointer, count: size)
    }
}
