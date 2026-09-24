#!/usr/bin/env swift
// Extracts a single frame from a video at an exact time using
// AVAssetImageGenerator with zero tolerance, and writes it as a PNG.
//
// Usage: swift scripts/frame-at.swift <file> <seconds> <out.png>
// Prints: "<width>x<height>" on success.

import AVFoundation
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("frame-at: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fail("usage: swift scripts/frame-at.swift <file> <seconds> <out.png>")
}
let inputURL = URL(fileURLWithPath: arguments[1])
guard let seconds = Double(arguments[2]) else {
    fail("invalid seconds: \(arguments[2])")
}
let outputURL = URL(fileURLWithPath: arguments[3])

guard FileManager.default.fileExists(atPath: inputURL.path) else {
    fail("file not found: \(inputURL.path)")
}

let asset = AVURLAsset(url: inputURL)
let generator = AVAssetImageGenerator(asset: asset)
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.appliesPreferredTrackTransform = true

let requestedTime = CMTime(seconds: seconds, preferredTimescale: 600)

let cgImage: CGImage
do {
    var actualTime = CMTime.zero
    cgImage = try generator.copyCGImage(at: requestedTime, actualTime: &actualTime)
} catch {
    fail("could not extract frame at \(seconds)s: \(error)")
}

guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fail("could not create PNG destination: \(outputURL.path)")
}
CGImageDestinationAddImage(destination, cgImage, nil)
guard CGImageDestinationFinalize(destination) else {
    fail("could not write PNG: \(outputURL.path)")
}

print("\(cgImage.width)x\(cgImage.height)")
