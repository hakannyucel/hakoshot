import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

@Suite("OutputService")
struct OutputServiceTests {
    @Test func writesPNGWithExpectedNameSizeAndDPI() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }

        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(FileNameTemplate.default.pattern, for: .outputFileNameTemplate)
        scratchSettings.settings.set(ImageFormat.png, for: .outputImageFormat)

        let service = OutputService(settings: scratchSettings.settings)
        let result = PostCaptureFixture.captureResult(pointWidth: 4, pointHeight: 3, scale: 2)

        let url = try service.save(result)

        #expect(url.deletingLastPathComponent() == scratchDir.url.resolvingSymlinksInPath())
        #expect(url.pathExtension == "png")
        #expect(url.lastPathComponent.hasPrefix("HakoShot "))
        #expect(FileManager.default.fileExists(atPath: url.path))

        let data = try Data(contentsOf: url)
        let decoded = try #require(ImageEncoder.decode(data))
        // 4x3 points at 2x scale -> 8x6 pixels (plan §4.7 Retina).
        #expect(decoded.width == 8)
        #expect(decoded.height == 6)

        // 72 * scale DPI metadata (plan §1.6/§4.7).
        #expect(ImageEncoder.dpi(of: data) == 144)
    }

    @Test func createsFolderWhenMissing() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        let nested = scratchDir.url.appendingPathComponent("nested/deeper", isDirectory: true)
        scratchSettings.settings.set(nested.path, for: .outputSaveFolderPath)

        #expect(!FileManager.default.fileExists(atPath: nested.path))

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult())

        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func collidingNamesGetDisambiguatingSuffix() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        // Fixed date -> every save renders the same base name, forcing collisions.
        scratchSettings.settings.set("HakoShot-fixed", for: .outputFileNameTemplate)

        let service = OutputService(settings: scratchSettings.settings)
        let result = PostCaptureFixture.captureResult()

        let first = try service.save(result)
        let second = try service.save(result)
        let third = try service.save(result)

        #expect(first.lastPathComponent == "HakoShot-fixed.png")
        #expect(second.lastPathComponent == "HakoShot-fixed (2).png")
        #expect(third.lastPathComponent == "HakoShot-fixed (3).png")
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(FileManager.default.fileExists(atPath: third.path))
    }

    @Test func neverOverwritesAnExistingFile() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set("fixed-name", for: .outputFileNameTemplate)

        let service = OutputService(settings: scratchSettings.settings)
        let first = try service.save(PostCaptureFixture.captureResult())
        let originalContents = try Data(contentsOf: first)

        // A second, differently-sized capture with the same rendered name
        // must not clobber the first file's bytes.
        let second = try service.save(PostCaptureFixture.captureResult(pointWidth: 10, pointHeight: 10))

        #expect(second != first)
        #expect(try Data(contentsOf: first) == originalContents)
    }

    @Test func honorsConfiguredFormatAndQuality() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(ImageFormat.jpeg, for: .outputImageFormat)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult())

        #expect(url.pathExtension == "jpg")
        let data = try Data(contentsOf: url)
        #expect(ImageEncoder.decode(data) != nil)
    }

    @Test func jpegFlattensTransparencyOntoWhite() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ))
        context.clear(CGRect(x: 0, y: 0, width: 4, height: 4))
        let transparent = try #require(context.makeImage())

        let flat = OutputService.flattenedOntoWhite(transparent)
        let data = try ImageEncoder.encode(flat, format: .png, options: ImageEncodeOptions())
        let decoded = try #require(ImageEncoder.decode(data))
        let pixel = try #require(Self.firstPixel(decoded))
        #expect(pixel.red > 250 && pixel.green > 250 && pixel.blue > 250 && pixel.alpha == 255)
    }

    @Test func honorsHEICFormat() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(ImageFormat.heic, for: .outputImageFormat)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult())

        #expect(url.pathExtension == "heic")
        let data = try Data(contentsOf: url)
        #expect(ImageEncoder.decode(data) != nil)
    }

    @Test func honorsWebPFormat() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(ImageFormat.webp, for: .outputImageFormat)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult())

        #expect(url.pathExtension == "webp")
        let data = try Data(contentsOf: url)
        #expect(ImageEncoder.decode(data) != nil)
    }

    @Test func scaleRetinaTo1xDownsamplesAndWrites1xDPI() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(true, for: .outputScaleRetinaTo1x)

        let service = OutputService(settings: scratchSettings.settings)
        // 4x3 points at 2x scale -> 8x6 px source; downsampled it must save at 4x3 px, 72 DPI.
        let result = PostCaptureFixture.captureResult(pointWidth: 4, pointHeight: 3, scale: 2)
        let url = try service.save(result)

        let data = try Data(contentsOf: url)
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == 4)
        #expect(decoded.height == 3)
        #expect(ImageEncoder.dpi(of: data) == 72)
    }

    @Test func scaleRetinaTo1xDoesNothingAt1xSource() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set(true, for: .outputScaleRetinaTo1x)

        let service = OutputService(settings: scratchSettings.settings)
        let result = PostCaptureFixture.captureResult(pointWidth: 4, pointHeight: 3, scale: 1)
        let url = try service.save(result)

        let data = try Data(contentsOf: url)
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == 4)
        #expect(decoded.height == 3)
        #expect(ImageEncoder.dpi(of: data) == 72)
    }

    @Test func appendsRetinaSuffixAt2xByDefaultOff() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set("fixed-name", for: .outputFileNameTemplate)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult(scale: 2))

        // Default off (plan §5.4): no "@2x" in the file name.
        #expect(url.lastPathComponent == "fixed-name.png")
    }

    @Test func appendsRetinaSuffixWhenEnabledAndStillRetina() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set("fixed-name", for: .outputFileNameTemplate)
        scratchSettings.settings.set(true, for: .outputAppendsRetinaSuffix)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult(scale: 2))

        #expect(url.lastPathComponent == "fixed-name@2x.png")
    }

    @Test func appendsRetinaSuffixOmittedAt1xSource() throws {
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set("fixed-name", for: .outputFileNameTemplate)
        scratchSettings.settings.set(true, for: .outputAppendsRetinaSuffix)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult(scale: 1))

        #expect(url.lastPathComponent == "fixed-name.png")
    }

    @Test func appendsRetinaSuffixOmittedWhenScaledTo1x() throws {
        // "@2x" would be misleading once the file has actually been
        // downsampled back to 1x — both settings on together must not
        // produce a "@2x" name for a 1x-pixel file.
        let scratchSettings = PostCaptureFixture.ScratchSettings()
        let scratchDir = PostCaptureFixture.ScratchDirectory()
        defer {
            scratchSettings.cleanup()
            scratchDir.cleanup()
        }
        scratchSettings.settings.set(scratchDir.url.path, for: .outputSaveFolderPath)
        scratchSettings.settings.set("fixed-name", for: .outputFileNameTemplate)
        scratchSettings.settings.set(true, for: .outputAppendsRetinaSuffix)
        scratchSettings.settings.set(true, for: .outputScaleRetinaTo1x)

        let service = OutputService(settings: scratchSettings.settings)
        let url = try service.save(PostCaptureFixture.captureResult(scale: 2))

        #expect(url.lastPathComponent == "fixed-name.png")
        let data = try Data(contentsOf: url)
        let decoded = try #require(ImageEncoder.decode(data))
        #expect(decoded.width == 4)
        #expect(decoded.height == 3)
    }

    private static func firstPixel(_ image: CGImage) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        return (bytes[0], bytes[1], bytes[2], bytes[3])
    }
}
