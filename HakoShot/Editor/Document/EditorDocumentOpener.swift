import AppKit
import CoreGraphics
import HakoKit
import ImageIO
import UniformTypeIdentifiers
import os

/// Opens images and `.hakoshot` projects in the editor from files, the Open
/// panel and the clipboard (menu "Open in Editor…", "Open from Clipboard",
/// `hakoshot://open-annotate`, Finder double-click).
enum EditorDocumentOpener {
    private static var log: Logger { EditorViewModel.log }

    /// Opens `url` (image or `.hakoshot`). Returns `false` and beeps when it
    /// can't be read.
    @discardableResult
    static func open(fileURL url: URL) async -> Bool {
        if ProjectFile.isProject(url) {
            do {
                let contents = try await readProject(at: url)
                return EditorWindowController.open(project: contents, projectURL: url) != nil
            } catch {
                return failed("cannot open project \(url.path): \(error)")
            }
        }
        guard let (image, scale) = await loadImage(at: url) else {
            return failed("cannot open image \(url.path)")
        }
        EditorWindowController.open(image: image, scale: scale, sourceURL: url)
        return true
    }

    /// Menu "Open in Editor…": pick images and/or projects.
    static func chooseAndOpen() {
        let panel = NSOpenPanel()
        panel.title = "Open in Editor"
        panel.prompt = "Open"
        panel.allowedContentTypes = [.image, ProjectFile.contentType]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate()
        panel.begin { response in
            guard response == .OK else { return }
            let urls = panel.urls
            Task { @MainActor in
                for url in urls { await open(fileURL: url) }
            }
        }
    }

    /// "Open from Clipboard": a copied image (or an image / project file).
    @discardableResult
    static func openFromClipboard(_ pasteboard: NSPasteboard = .general) async -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first(where: { ProjectFile.isProject($0) || isImageFile($0) }) {
            return await open(fileURL: url)
        }
        guard let (image, scale) = clipboardImage(pasteboard) else {
            return failed("no image on the clipboard")
        }
        EditorWindowController.open(image: image, scale: scale)
        log.notice("opened clipboard image \(image.width)x\(image.height) px @\(scale)x")
        return true
    }

    // MARK: Loading

    /// Reads a package off the main thread.
    static func readProject(at url: URL) async throws -> ProjectFile.Contents {
        try await Task.detached(priority: .userInitiated) { try ProjectFile.read(from: url) }.value
    }

    /// Decoded image + scale from its DPI (144 → 2x).
    static func loadImage(at url: URL) async -> (CGImage, CGFloat)? {
        let loaded = await Task.detached(priority: .userInitiated) { () -> ImageBox? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
            else { return nil }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            let dpi = (properties?[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue ?? 72
            return ImageBox(image: image, scale: scaleForDPI(dpi))
        }.value
        return loaded.map { ($0.image, $0.scale) }
    }

    private static func clipboardImage(_ pasteboard: NSPasteboard) -> (CGImage, CGFloat)? {
        guard let nsImage = NSImage(pasteboard: pasteboard) else { return nil }
        var rect = CGRect(origin: .zero, size: nsImage.size)
        // Largest representation = full pixels.
        let best = nsImage.representations.max { $0.pixelsWide < $1.pixelsWide }
        guard let image = best?.cgImage(forProposedRect: &rect, context: nil, hints: nil)
            ?? nsImage.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }
        let points = nsImage.size.width
        let scale: CGFloat = points > 0 ? max(1, (CGFloat(image.width) / points).rounded()) : 1
        return (image, scale)
    }

    nonisolated static func scaleForDPI(_ dpi: Double) -> CGFloat {
        guard dpi.isFinite, dpi > 0 else { return 1 }
        return CGFloat(max(1, (dpi / 72).rounded()))
    }

    private static func isImageFile(_ url: URL) -> Bool {
        (UTType(filenameExtension: url.pathExtension)?.conforms(to: .image)) ?? false
    }

    private static func failed(_ message: String) -> Bool {
        log.error("\(message, privacy: .public)")
        NSSound.beep()
        return false
    }
}

/// `CGImage` is immutable; carries a decoded image out of a detached task.
private nonisolated struct ImageBox: @unchecked Sendable {
    let image: CGImage
    let scale: CGFloat
}
