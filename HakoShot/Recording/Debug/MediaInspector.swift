#if DEBUG
import AVFoundation
import CoreMedia
import Foundation
import ImageIO

/// Produces the same JSON media summary as `scripts/media-info.swift`
/// (duration, file size, and a track list for video/audio containers, or
/// frame/delay/loop information for `.gif`), for the in-app
/// `debug-media-info?filepath=&out=` URL handler.
///
/// Kept `nonisolated` throughout: the app target defaults new declarations to
/// `@MainActor`, but media inspection does file and AVFoundation I/O that has
/// no reason to run on the main actor.
nonisolated enum MediaInspector {
    struct PixelSize: Codable, Sendable, Equatable {
        var width: Int
        var height: Int
    }

    struct TrackInfo: Codable, Sendable, Equatable {
        var kind: String
        var codec: String
        var pixelSize: PixelSize?
        var nominalFrameRate: Double?
        var channelCount: Int?
        var sampleRate: Double?
        var duration: Double
    }

    struct GIFInfo: Codable, Sendable, Equatable {
        var frameCount: Int
        var delaysCentiseconds: [Int]
        var pixelSize: PixelSize
        var loopCount: Int
        var totalDuration: Double
    }

    struct Info: Codable, Sendable, Equatable {
        var kind: String
        var path: String
        var fileSize: Int
        var duration: Double
        var tracks: [TrackInfo]?
        var gif: GIFInfo?
    }

    enum InspectorError: Error, Sendable {
        case fileNotFound(URL)
        case couldNotReadGIF(URL)
    }

    /// Returns the same JSON shape as `scripts/media-info.swift`'s stdout,
    /// decoded into a `[String: Any]` so it can be embedded directly in a
    /// debug URL's JSON response.
    nonisolated static func info(for url: URL) async throws -> [String: Any] {
        let info = try await collect(for: url)
        let data = try JSONEncoder().encode(info)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    /// Same as `info(for:)` but returns the typed, Codable result directly
    /// (useful from Swift call sites and tests that don't want to round-trip
    /// through `[String: Any]`).
    nonisolated static func collect(for url: URL) async throws -> Info {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InspectorError.fileNotFound(url)
        }
        if url.pathExtension.lowercased() == "gif" {
            return try gifInfo(url: url)
        }
        return try await videoInfo(url: url)
    }

    // MARK: - GIF (ImageIO)

    nonisolated private static func gifInfo(url: URL) throws -> Info {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw InspectorError.couldNotReadGIF(url)
        }
        let frameCount = CGImageSourceGetCount(source)
        var delaysCentiseconds: [Int] = []
        var pixelWidth = 0
        var pixelHeight = 0

        for index in 0..<frameCount {
            if index == 0, let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) {
                pixelWidth = cgImage.width
                pixelHeight = cgImage.height
            }
            var delaySeconds = 0.0
            if let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            {
                if let unclamped = gifProperties[kCGImagePropertyGIFUnclampedDelayTime] as? Double {
                    delaySeconds = unclamped
                } else if let clamped = gifProperties[kCGImagePropertyGIFDelayTime] as? Double {
                    delaySeconds = clamped
                }
            }
            delaysCentiseconds.append(Int((delaySeconds * 100).rounded()))
        }

        var loopCount = 0
        if let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any],
            let loop = gifProperties[kCGImagePropertyGIFLoopCount] as? Int
        {
            loopCount = loop
        }

        let totalDuration = Double(delaysCentiseconds.reduce(0, +)) / 100.0
        let gif = GIFInfo(
            frameCount: frameCount,
            delaysCentiseconds: delaysCentiseconds,
            pixelSize: PixelSize(width: pixelWidth, height: pixelHeight),
            loopCount: loopCount,
            totalDuration: totalDuration
        )
        return Info(kind: "gif", path: url.path, fileSize: fileSize(of: url), duration: totalDuration, tracks: nil, gif: gif)
    }

    // MARK: - Video/audio container (AVFoundation)

    nonisolated private static func videoInfo(url: URL) async throws -> Info {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.load(.tracks)

        var trackObjects: [TrackInfo] = []
        for track in tracks {
            if let info = try await trackInfo(track) {
                trackObjects.append(info)
            }
        }

        return Info(
            kind: "video",
            path: url.path,
            fileSize: fileSize(of: url),
            duration: CMTimeGetSeconds(duration),
            tracks: trackObjects,
            gif: nil
        )
    }

    nonisolated private static func trackInfo(_ track: AVAssetTrack) async throws -> TrackInfo? {
        let mediaType = track.mediaType
        let timeRange = try await track.load(.timeRange)
        let duration = CMTimeGetSeconds(timeRange.duration)
        let formatDescriptions = try await track.load(.formatDescriptions)
        let codec = formatDescriptions.first.map { fourCCString(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"

        switch mediaType {
        case .video:
            let naturalSize = try await track.load(.naturalSize)
            let nominalFrameRate = try await track.load(.nominalFrameRate)
            return TrackInfo(
                kind: "video",
                codec: codec,
                pixelSize: PixelSize(width: Int(naturalSize.width.rounded()), height: Int(naturalSize.height.rounded())),
                nominalFrameRate: Double(nominalFrameRate),
                channelCount: nil,
                sampleRate: nil,
                duration: duration
            )
        case .audio:
            var channelCount = 0
            var sampleRate = 0.0
            if let formatDescription = formatDescriptions.first,
                let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
            {
                channelCount = Int(asbdPointer.pointee.mChannelsPerFrame)
                sampleRate = asbdPointer.pointee.mSampleRate
            }
            return TrackInfo(
                kind: "audio",
                codec: codec,
                pixelSize: nil,
                nominalFrameRate: nil,
                channelCount: channelCount,
                sampleRate: sampleRate,
                duration: duration
            )
        default:
            return nil
        }
    }

    nonisolated private static func fourCCString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >> 8) & 0xff),
            UInt8(code & 0xff),
        ]
        let scalars = bytes.map { Unicode.Scalar($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    nonisolated private static func fileSize(of url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
#endif
