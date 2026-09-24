import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import HakoKit
import ImageIO
import os
import UniformTypeIdentifiers

/// A cursor image as read from the system, in points.
struct CursorImageSnapshot {
    /// Rendered at `CursorShapeSampler.renderScale` × the point size.
    var image: CGImage
    var hotSpot: CGPoint
    var pointSize: CGSize
}

/// Polls the system cursor (`NSCursor.currentSystem`) at ~20 Hz (plan §1.6).
/// `currentSystem` returns a new object on every call (R0.2 spike 4), so a
/// shape is identified by a hash of its rendered pixels. Each new shape is
/// written once as `cursors/<hash>.png` (rendered at 2×) and gets the next
/// `shapeIndex` (= index into `RecordingMetadata.cursorShapes`).
///
/// `nil` from the provider (no cursor / hidden) keeps the last index and sets
/// `isHidden`.
@MainActor
final class CursorShapeSampler {
    static let defaultInterval: TimeInterval = 0.05
    /// Pixels per point of the rendered PNG (and of the hashed bitmap).
    static let renderScale: CGFloat = 2

    let cursorsFolder: URL
    private let interval: TimeInterval
    private let provider: () -> CursorImageSnapshot?
    private var timer: Timer?
    private var indexByHash: [String: UInt16] = [:]

    private(set) var shapes: [RecordingCursorShape] = []
    private(set) var currentIndex: UInt16 = 0
    private(set) var isHidden = false

    /// - Parameter cursorsFolder: `<session>/cursors/`; created on the first shape.
    init(cursorsFolder: URL, interval: TimeInterval = defaultInterval,
         provider: @escaping () -> CursorImageSnapshot? = { CursorShapeSampler.systemCursor() }) {
        self.cursorsFolder = cursorsFolder
        self.interval = interval
        self.provider = provider
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        sampleNow()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Reads the cursor once and updates `currentIndex` / `isHidden`.
    func sampleNow() {
        guard let snapshot = provider() else {
            isHidden = true
            return
        }
        isHidden = false
        if let index = register(snapshot) { currentIndex = index }
    }

    /// Index of the snapshot's shape, writing a new PNG when it's new.
    /// `nil` when the image can't be hashed or the index space is full.
    @discardableResult
    func register(_ snapshot: CursorImageSnapshot) -> UInt16? {
        guard let hash = Self.hash(of: snapshot.image) else { return nil }
        if let index = indexByHash[hash] { return index }
        guard shapes.count < Int(UInt16.max) else { return nil }
        let shape = RecordingCursorShape(
            hash: hash,
            hotSpotX: Double(snapshot.hotSpot.x),
            hotSpotY: Double(snapshot.hotSpot.y),
            width: Double(snapshot.pointSize.width),
            height: Double(snapshot.pointSize.height)
        )
        let url = cursorsFolder.deletingLastPathComponent().appending(path: shape.fileName)
        do {
            try FileManager.default.createDirectory(at: cursorsFolder, withIntermediateDirectories: true)
            try Self.writePNG(snapshot.image, to: url)
        } catch {
            Log.recording.error("cursor shape \(hash, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        let index = UInt16(shapes.count)
        shapes.append(shape)
        indexByHash[hash] = index
        return index
    }

    // MARK: System cursor

    /// The current system cursor rendered at `renderScale`; `nil` when there
    /// is none (the cursor is hidden) or it has no size.
    static func systemCursor() -> CursorImageSnapshot? {
        guard let cursor = NSCursor.currentSystem else { return nil }
        return snapshot(of: cursor.image, hotSpot: cursor.hotSpot)
    }

    /// Renders an `NSImage` at `renderScale` into an sRGB bitmap.
    static func snapshot(of image: NSImage, hotSpot: CGPoint) -> CursorImageSnapshot? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let width = Int((size.width * renderScale).rounded(.up))
        let height = Int((size.height * renderScale).rounded(.up))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let rendered = context.makeImage() else { return nil }
        return CursorImageSnapshot(image: rendered, hotSpot: hotSpot, pointSize: size)
    }

    // MARK: Hash and PNG

    /// SHA-256 (first 16 bytes, hex) of the image's size and RGBA pixels.
    /// Stable across calls for the same shape; cheaper than encoding a PNG on
    /// every poll.
    nonisolated static func hash(of image: CGImage) -> String? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var hasher = SHA256()
        withUnsafeBytes(of: UInt32(width).littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: UInt32(height).littleEndian) { hasher.update(bufferPointer: $0) }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(start: data, count: width * height * 4))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
