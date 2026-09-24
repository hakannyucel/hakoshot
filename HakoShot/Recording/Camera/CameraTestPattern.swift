import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// A camera stand-in: eight vertical color bars (white, yellow, cyan,
/// green, magenta, red, blue, black) plus a white square whose x moves with
/// `frame`. Used by the bubble when no camera is available or authorized
/// (DEBUG snapshots, tests) and by `CameraRecorder` tests — never touches
/// the camera or TCC.
nonisolated enum CameraTestPattern {
    /// Bar colors, left to right (sRGB 0…255).
    static let bars: [(r: UInt8, g: UInt8, b: UInt8)] = [
        (255, 255, 255), (255, 255, 0), (0, 255, 255), (0, 255, 0),
        (255, 0, 255), (255, 0, 0), (0, 0, 255), (0, 0, 0),
    ]

    /// Bar index at horizontal fraction `x` (0…1) of an unmirrored frame.
    static func barIndex(atFraction x: Double) -> Int {
        min(max(Int(x * Double(bars.count)), 0), bars.count - 1)
    }

    /// BGRA bytes of one frame (top row first).
    static func pixels(width: Int, height: Int, frame: Int = 0) -> [UInt8] {
        guard width > 0, height > 0 else { return [] }
        var row = [UInt8](repeating: 255, count: width * 4)
        for x in 0..<width {
            let color = bars[barIndex(atFraction: (Double(x) + 0.5) / Double(width))]
            row[x * 4] = color.b
            row[x * 4 + 1] = color.g
            row[x * 4 + 2] = color.r
        }
        var data = [UInt8]()
        data.reserveCapacity(width * height * 4)
        for _ in 0..<height { data.append(contentsOf: row) }
        let square = max(height / 6, 2)
        let squareX = width > square ? (frame * 8) % (width - square) : 0
        let squareY = max(height - square - max(height / 12, 1), 0)
        for y in squareY..<min(squareY + square, height) {
            let start = (y * width + squareX) * 4
            let end = min(start + square * 4, (y + 1) * width * 4)
            for i in start..<end { data[i] = 255 }
        }
        return data
    }

    static func image(width: Int = 640, height: Int = 360, frame: Int = 0) -> CGImage? {
        let bytes = pixels(width: width, height: height, frame: frame)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    static func pixelBuffer(width: Int, height: Int, frame: Int = 0) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()]
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = pixels(width: width, height: height, frame: frame)
        bytes.withUnsafeBytes { source in
            for y in 0..<height {
                (base + y * rowBytes).copyMemory(from: source.baseAddress! + y * width * 4, byteCount: width * 4)
            }
        }
        return buffer
    }

    /// A video sample buffer of the pattern stamped at `pts` (host clock).
    static func sampleBuffer(width: Int, height: Int, frame: Int, pts: CMTime, duration: CMTime = CMTime(value: 1, timescale: 30)) -> CMSampleBuffer? {
        guard let pixelBuffer = pixelBuffer(width: width, height: height, frame: frame) else { return nil }
        return sampleBuffer(pixelBuffer: pixelBuffer, pts: pts, duration: duration)
    }

    /// A video sample buffer wrapping `pixelBuffer` at `pts` (reuse one
    /// buffer for many frames).
    static func sampleBuffer(pixelBuffer: CVPixelBuffer, pts: CMTime, duration: CMTime = CMTime(value: 1, timescale: 30)) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr,
              let format
        else { return nil }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
