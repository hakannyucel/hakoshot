import AppKit
import CoreGraphics
import Foundation
import HakoKit

/// Errors `ClipboardWriter.write(_:fileURL:)` can throw.
enum ClipboardWriterError: Error, Sendable {
    case pngEncodingFailed(underlying: any Error)
    case tiffRepresentationFailed
}

/// Writes a capture to a pasteboard as PNG + TIFF (plan §1.6: "`NSPasteboard`:
/// PNG + TIFF verisi; … dosya URL'si de"), so both PNG-preferring apps (e.g.
/// Preview) and legacy TIFF-only apps (e.g. some older AppKit paste targets)
/// get a usable image. `pasteboard` defaults to `.general` but is injectable
/// so tests use a private named pasteboard instead of the real system
/// clipboard.
struct ClipboardWriter {
    var pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Clears `pasteboard` and writes `image` as PNG + TIFF. When `fileURL`
    /// is given (the capture was also saved to disk), its absolute string is
    /// written too under `.fileURL`, for apps that only look for a file
    /// reference. Returns whether the write succeeded (mirrors
    /// `NSPasteboard.writeObjects`' own return value).
    @discardableResult
    func write(_ image: CGImage, fileURL: URL? = nil) throws -> Bool {
        let pngData: Data
        do {
            pngData = try ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions(compressionQuality: 1, dpi: 72))
        } catch {
            throw ClipboardWriterError.pngEncodingFailed(underlying: error)
        }

        guard let bitmap = NSBitmapImageRep(data: pngData),
              let tiffData = bitmap.representation(using: .tiff, properties: [:])
        else {
            throw ClipboardWriterError.tiffRepresentationFailed
        }

        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        item.setData(tiffData, forType: .tiff)
        if let fileURL {
            item.setString(fileURL.absoluteString, forType: .fileURL)
        }

        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }

    /// Clears `pasteboard` and writes a file reference to `url` (kayit-teknik-plan
    /// §4.15: recordings go on the clipboard as `public.file-url`, no embedded data),
    /// so pasting into Finder copies the file and Slack / Mail attach it. The URL is
    /// written as an `NSURL` pasteboard object (`public.file-url` + its string
    /// representation). Returns whether the write succeeded.
    @discardableResult
    func writeFile(url: URL) -> Bool {
        pasteboard.clearContents()
        return pasteboard.writeObjects([url.standardizedFileURL as NSURL])
    }
}
