import AppKit
import UniformTypeIdentifiers

/// Drag-and-drop of images onto the editor canvas (combine, WP5.4).
enum CanvasDropSupport {
    static let acceptedTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier),
    ]

    private static let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Whether the drag carries at least one image file or image data.
    static func canAccept(_ pasteboard: NSPasteboard) -> Bool {
        EditorViewModel.hasImage(on: pasteboard)
    }

    /// Image file URLs on the drag pasteboard.
    static func imageURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL]) ?? []
    }
}

extension CanvasView {
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard dropOperation(for: sender) == .copy else { return false }
        let pasteboard = sender.draggingPasteboard
        let urls = CanvasDropSupport.imageURLs(on: pasteboard)
        var images = model.loadImages(at: urls)
        if urls.isEmpty, let image = EditorViewModel.image(from: pasteboard) { images = [image] }
        guard !images.isEmpty else { return false }
        let point = geometry.canvasPoint(fromView: convert(sender.draggingLocation, from: nil))
        textEditor?.end()
        model.dropImages(images, at: point)
        window?.makeFirstResponder(self)
        return true
    }

    private func dropOperation(for sender: any NSDraggingInfo) -> NSDragOperation {
        guard !model.isCropping, CanvasDropSupport.canAccept(sender.draggingPasteboard) else { return [] }
        return .copy
    }
}
