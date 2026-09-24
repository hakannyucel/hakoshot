#!/usr/bin/env swift
// Prints the RGBA (0-255) value of one or more pixels in a PNG, using a
// top-left origin (x grows right, y grows down — matches frame-at.swift's
// output and typical image-coordinate conventions).
//
// Usage: swift scripts/pixel-probe.swift <png> <x> <y> [<x> <y> ...]
// Prints a JSON array: [{"x":0,"y":0,"r":255,"g":0,"b":0,"a":255}, ...]

import AppKit
import CoreGraphics
import Foundation
import ImageIO

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("pixel-probe: \(message)\n".data(using: .utf8)!)
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, (arguments.count - 1) % 2 == 0 else {
    fail("usage: swift scripts/pixel-probe.swift <png> <x> <y> [<x> <y> ...]")
}

let pngPath = arguments[0]
let coordinateArguments = arguments.dropFirst()
var coordinates: [(x: Int, y: Int)] = []
var iterator = coordinateArguments.makeIterator()
while let xString = iterator.next(), let yString = iterator.next() {
    guard let x = Int(xString), let y = Int(yString) else {
        fail("invalid coordinate: \(xString), \(yString)")
    }
    coordinates.append((x, y))
}

guard FileManager.default.fileExists(atPath: pngPath) else {
    fail("file not found: \(pngPath)")
}
let url = URL(fileURLWithPath: pngPath)
guard
    let source = CGImageSourceCreateWithURL(url as CFURL, nil),
    let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    fail("could not read PNG: \(pngPath)")
}

// NSBitmapImageRep.colorAt(x:y:) uses a top-left pixel origin, which matches
// the coordinate system used by frame-at.swift's output and the rest of the
// recording pipeline (see kayit-teknik-plan.md §2.2 "video içi = çıktı
// pikseli, sol-üst köken").
let bitmap = NSBitmapImageRep(cgImage: cgImage)

var results: [[String: Any]] = []
for coordinate in coordinates {
    guard coordinate.x >= 0, coordinate.x < bitmap.pixelsWide, coordinate.y >= 0, coordinate.y < bitmap.pixelsHigh else {
        fail("coordinate (\(coordinate.x),\(coordinate.y)) is out of bounds for \(bitmap.pixelsWide)x\(bitmap.pixelsHigh) image")
    }
    guard
        let rawColor = bitmap.colorAt(x: coordinate.x, y: coordinate.y),
        let color = rawColor.usingColorSpace(.deviceRGB)
    else {
        fail("could not read pixel (\(coordinate.x),\(coordinate.y))")
    }
    let r = Int((color.redComponent * 255).rounded())
    let g = Int((color.greenComponent * 255).rounded())
    let b = Int((color.blueComponent * 255).rounded())
    let a = Int((color.alphaComponent * 255).rounded())
    results.append(["x": coordinate.x, "y": coordinate.y, "r": r, "g": g, "b": b, "a": a])
}

guard let data = try? JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]) else {
    fail("could not serialize JSON")
}
print(String(data: data, encoding: .utf8) ?? "[]")
