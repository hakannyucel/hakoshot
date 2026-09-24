import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Uses a private named pasteboard (not `.general`) so these tests never
/// touch the real system clipboard.
@Suite("ClipboardWriter")
struct ClipboardWriterTests {
    private func makePrivatePasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.hakanyucel.hakoshot.tests.\(UUID().uuidString)"))
    }

    @Test func writesPNGAndTIFFRoundTrip() throws {
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }

        let image = PostCaptureFixture.image(pointWidth: 5, pointHeight: 5, scale: 1)
        let writer = ClipboardWriter(pasteboard: pasteboard)

        let succeeded = try writer.write(image)
        #expect(succeeded)

        let pngData = try #require(pasteboard.data(forType: .png))
        let decodedPNG = try #require(ImageEncoder.decode(pngData))
        #expect(decodedPNG.width == 5)
        #expect(decodedPNG.height == 5)

        let tiffData = try #require(pasteboard.data(forType: .tiff))
        let bitmap = try #require(NSBitmapImageRep(data: tiffData))
        #expect(bitmap.pixelsWide == 5)
        #expect(bitmap.pixelsHigh == 5)
    }

    @Test func writesFileURLWhenProvided() throws {
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }

        let image = PostCaptureFixture.image()
        let fileURL = URL(fileURLWithPath: "/tmp/HakoShot 2026-09-23 at 12.00.00.png")
        let writer = ClipboardWriter(pasteboard: pasteboard)

        try writer.write(image, fileURL: fileURL)

        let stored = pasteboard.string(forType: .fileURL)
        #expect(stored == fileURL.absoluteString)
    }

    @Test func omitsFileURLTypeWhenNotProvided() throws {
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }

        try ClipboardWriter(pasteboard: pasteboard).write(PostCaptureFixture.image())

        #expect(pasteboard.string(forType: .fileURL) == nil)
    }

    @Test func clearsPriorContentsBeforeWriting() throws {
        let pasteboard = makePrivatePasteboard()
        defer { pasteboard.releaseGlobally() }

        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("stale", forType: .string)

        try ClipboardWriter(pasteboard: pasteboard).write(PostCaptureFixture.image())

        #expect(pasteboard.string(forType: .string) == nil)
        #expect(pasteboard.data(forType: .png) != nil)
    }
}
