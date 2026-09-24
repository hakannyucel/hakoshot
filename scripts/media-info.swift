#!/usr/bin/env swift
// Prints a small JSON summary of a media file's tracks, duration and file size.
// Handles ordinary AVFoundation-readable media (video/audio containers) and,
// separately, animated GIFs (inspected with ImageIO since AVFoundation does
// not expose GIF frame timing).
//
// Usage: swift scripts/media-info.swift <file>
//
// JSON shape (video/audio container):
//   {
//     "kind": "video",
//     "path": "...",
//     "fileSize": 123456,
//     "duration": 3.0,
//     "tracks": [
//       {"kind":"video","codec":"avc1","pixelSize":{"width":1280,"height":720},
//        "nominalFrameRate":30.0,"duration":3.0},
//       {"kind":"audio","codec":"aac ","channelCount":2,"sampleRate":48000.0,"duration":3.0}
//     ]
//   }
//
// JSON shape (.gif):
//   {
//     "kind": "gif",
//     "path": "...",
//     "fileSize": 123456,
//     "duration": 2.75,
//     "gif": {
//       "frameCount": 10,
//       "delaysCentiseconds": [5,10,...],
//       "pixelSize": {"width":64,"height":64},
//       "loopCount": 0,
//       "totalDuration": 2.75
//     }
//   }

import AVFoundation
import CoreMedia
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("media-info: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func fourCCString(_ code: FourCharCode) -> String {
    let bytes: [UInt8] = [
        UInt8((code >> 24) & 0xff),
        UInt8((code >> 16) & 0xff),
        UInt8((code >> 8) & 0xff),
        UInt8(code & 0xff),
    ]
    let scalars = bytes.map { Unicode.Scalar($0) }
    return String(String.UnicodeScalarView(scalars))
}

func fileSize(of url: URL) -> Int {
    (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
}

func printJSON(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
        fail("could not serialize JSON")
    }
    print(String(data: data, encoding: .utf8) ?? "{}")
}

// MARK: - GIF inspection (ImageIO)

func gifInfo(url: URL) -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
        fail("could not open GIF: \(url.path)")
    }
    let frameCount = CGImageSourceGetCount(source)
    var delaysCentiseconds: [Int] = []
    var pixelWidth = 0
    var pixelHeight = 0

    for i in 0..<frameCount {
        if let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil), i == 0 {
            pixelWidth = cgImage.width
            pixelHeight = cgImage.height
        }
        var delaySeconds = 0.0
        if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
            let gifProps = props[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        {
            if let unclamped = gifProps[kCGImagePropertyGIFUnclampedDelayTime] as? Double {
                delaySeconds = unclamped
            } else if let clamped = gifProps[kCGImagePropertyGIFDelayTime] as? Double {
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

    let totalDuration = delaysCentiseconds.reduce(0, +).doubleValueFromCentiseconds

    let gif: [String: Any] = [
        "frameCount": frameCount,
        "delaysCentiseconds": delaysCentiseconds,
        "pixelSize": ["width": pixelWidth, "height": pixelHeight],
        "loopCount": loopCount,
        "totalDuration": totalDuration,
    ]
    return [
        "kind": "gif",
        "path": url.path,
        "fileSize": fileSize(of: url),
        "duration": totalDuration,
        "gif": gif,
    ]
}

extension Int {
    var doubleValueFromCentiseconds: Double { Double(self) / 100.0 }
}

// MARK: - Video/audio container inspection (AVFoundation)

func trackInfo(_ track: AVAssetTrack) async throws -> [String: Any]? {
    let mediaType = track.mediaType
    let timeRange = try await track.load(.timeRange)
    let duration = CMTimeGetSeconds(timeRange.duration)
    let formatDescriptions = try await track.load(.formatDescriptions)
    let codec = formatDescriptions.first.map { fourCCString(CMFormatDescriptionGetMediaSubType($0)) } ?? "unknown"

    switch mediaType {
    case .video:
        let naturalSize = try await track.load(.naturalSize)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        return [
            "kind": "video",
            "codec": codec,
            "pixelSize": ["width": Int(naturalSize.width.rounded()), "height": Int(naturalSize.height.rounded())],
            "nominalFrameRate": Double(nominalFrameRate),
            "duration": duration,
        ]
    case .audio:
        var channelCount = 0
        var sampleRate = 0.0
        if let formatDescription = formatDescriptions.first,
            let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        {
            channelCount = Int(asbdPointer.pointee.mChannelsPerFrame)
            sampleRate = asbdPointer.pointee.mSampleRate
        }
        return [
            "kind": "audio",
            "codec": codec,
            "channelCount": channelCount,
            "sampleRate": sampleRate,
            "duration": duration,
        ]
    default:
        return nil
    }
}

func videoInfo(url: URL) async throws -> [String: Any] {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.load(.tracks)

    var trackObjects: [[String: Any]] = []
    for track in tracks {
        if let info = try await trackInfo(track) {
            trackObjects.append(info)
        }
    }

    return [
        "kind": "video",
        "path": url.path,
        "fileSize": fileSize(of: url),
        "duration": CMTimeGetSeconds(duration),
        "tracks": trackObjects,
    ]
}

// MARK: - Entry point

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    fail("usage: swift scripts/media-info.swift <file>")
}
let inputURL = URL(fileURLWithPath: arguments[1])
guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("file not found: \(inputURL.path)")
}

if inputURL.pathExtension.lowercased() == "gif" {
    printJSON(gifInfo(url: inputURL))
} else {
    do {
        let info = try await videoInfo(url: inputURL)
        printJSON(info)
    } catch {
        fail("could not read media: \(error)")
    }
}
