import AppKit
import CoreGraphics
import HakoKit
import ImageIO
import UniformTypeIdentifiers
import os

/// Canvas operations (WP5.4): combine images (⌘I file, ⇧⌘I new capture, ⌘V
/// image, drag and drop), canvas size and resize image. Every operation is one
/// undo step; added images go into the asset box and are saved with the
/// `.hakoshot` project like any other asset.
extension EditorViewModel {
    // MARK: Hooks

    /// ⇧⌘I "Add New Screenshot": starts a capture and calls `deliver` with the
    /// result (`image`, `scale`). Set by the app (AppCoordinator); while `nil`,
    /// ⇧⌘I adds the image on the clipboard instead.
    static var captureForCombine: ((@escaping @MainActor (CGImage, CGFloat) -> Void) -> Void)?

    // MARK: Adding images

    /// Registers `image` and returns an `.image` annotation of its pixel size
    /// (scaled from `scale` to the document's scale when both are known).
    func makeImageAnnotation(_ image: CGImage, scale: CGFloat? = nil, origin: CGPoint = .zero) -> Annotation {
        let id = addAsset(image)
        let factor = scale.map { $0 > 0 ? canvasScale / $0 : 1 } ?? 1
        let size = CGSize(width: (CGFloat(image.width) * factor).rounded(), height: (CGFloat(image.height) * factor).rounded())
        return Annotation(
            kind: .image(ImageShape(assetID: id, frame: CGRect(origin: origin, size: size))),
            style: AnnotationStyle(opacity: 1, shadow: false)
        )
    }

    /// Places `images` one after another next to the content on `edge`
    /// (canvas space; `nil` = the right side *as displayed*, i.e. after
    /// rotate / flip), one "Combine Images" undo step, selecting the last.
    func combine(_ images: [(CGImage, CGFloat?)], edge: CombineEdge? = nil) {
        guard !images.isEmpty else { return }
        let edge = edge ?? Self.canvasEdge(forDisplayed: .right, in: store.document)
        commitTextEditing?()
        if isCropping { cancelCrop() }
        batch("Combine Images") {
            for (image, scale) in images {
                perform(.combineImage(makeImageAnnotation(image, scale: scale), edge: edge, spacing: 0))
            }
        }
        if tool != .move { perform(.setTool(.move)) }
        if let last = store.document.annotations.last { perform(.select([last.id])) }
        showStatus(images.count == 1 ? "Image added" : "\(images.count) images added")
        Self.log.notice("combined \(images.count) image(s); canvas \(self.document.canvas.width)x\(self.document.canvas.height)")
    }

    /// Adds `image` centered on `point` (canvas pixels); the canvas grows if
    /// it doesn't fit.
    func insertImage(_ image: CGImage, scale: CGFloat? = nil, centeredAt point: CGPoint) {
        commitTextEditing?()
        if isCropping { cancelCrop() }
        var annotation = makeImageAnnotation(image, scale: scale)
        let size = annotation.bounds.size
        annotation = annotation.translated(by: CGVector(dx: (point.x - size.width / 2).rounded(), dy: (point.y - size.height / 2).rounded()))
        perform(.insertImage(annotation))
        if tool != .move { perform(.setTool(.move)) }
        perform(.select([annotation.id]))
        showStatus("Image added")
    }

    /// Image files (drops, ⌘I). Unreadable files are reported and skipped.
    func loadImages(at urls: [URL]) -> [CGImage] {
        urls.compactMap { url in
            guard let image = Self.loadFullImage(at: url) else {
                showStatus("Could not open \(url.lastPathComponent)")
                Self.log.error("combine: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            return image
        }
    }

    /// ⌘I "Add Image…": open panel (multiple selection), combined to the right.
    func chooseImagesToCombine(from window: NSWindow?) {
        commitTextEditing?()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to add next to this screenshot"
        panel.prompt = "Add"
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK else { return }
            self.combine(self.loadImages(at: panel.urls).map { ($0, nil) })
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handle) } else { handle(panel.runModal()) }
    }

    /// ⇧⌘I "Add New Screenshot": captures through the app hook, else adds the
    /// clipboard image.
    func addNewScreenshot() {
        commitTextEditing?()
        if let capture = Self.captureForCombine {
            capture { [weak self] image, scale in self?.combine([(image, scale)]) }
            return
        }
        guard let image = Self.image(from: .general) else {
            showStatus("No image on the clipboard")
            return
        }
        combine([(image, nil)])
    }

    /// ⌘V with an image (or image file) on the pasteboard. Small images land
    /// centered on the visible content; screenshot-sized ones are combined to
    /// the right. Returns `false` when there's no image.
    @discardableResult
    func pasteImage(from pasteboard: NSPasteboard = .general) -> Bool {
        guard let image = Self.image(from: pasteboard) else { return false }
        let visible = store.document.visibleRect
        if Self.pastesAsOverlay(imageSize: CGSize(width: image.width, height: image.height), visible: visible.size) {
            insertImage(image, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
        } else {
            combine([(image, nil)])
        }
        return true
    }

    /// Paste placement rule: overlay when the image covers at most a quarter
    /// of the visible area and fits inside it (pure, tested).
    nonisolated static func pastesAsOverlay(imageSize: CGSize, visible: CGSize) -> Bool {
        imageSize.width <= visible.width && imageSize.height <= visible.height
            && imageSize.width * imageSize.height <= 0.25 * visible.width * visible.height
    }

    /// Drop of image files / image data at `point` (canvas pixels): inside the
    /// visible content the image is placed there; outside it (the gray
    /// margin) it is combined on that side.
    func dropImages(_ images: [CGImage], at point: CGPoint) {
        guard !images.isEmpty else { return }
        if let edge = Self.combineEdge(for: point, visible: store.document.visibleRect) {
            combine(images.map { ($0, nil) }, edge: edge)
        } else if images.count == 1, let image = images.first {
            insertImage(image, centeredAt: point)
        } else {
            combine(images.map { ($0, nil) })
        }
    }

    /// Side of `visible` that `point` lies beyond (the farthest one), or `nil`
    /// when it is inside (pure, tested).
    nonisolated static func combineEdge(for point: CGPoint, visible: CGRect) -> CombineEdge? {
        guard !visible.contains(point) else { return nil }
        let distances: [(CombineEdge, CGFloat)] = [
            (.left, visible.minX - point.x),
            (.right, point.x - visible.maxX),
            (.top, visible.minY - point.y),
            (.bottom, point.y - visible.maxY),
        ]
        return distances.max { $0.1 < $1.1 }?.0
    }

    /// The canvas side that appears as `edge` after rotate / flip (pure, tested).
    nonisolated static func canvasEdge(forDisplayed edge: CombineEdge, in document: ProjectDocument) -> CombineEdge {
        guard !document.transform.isIdentity else { return edge }
        let bounds = CropMath.displayBounds(of: document)
        let outside: CGPoint = switch edge {
        case .right: CGPoint(x: bounds.maxX + 1, y: bounds.midY)
        case .left: CGPoint(x: bounds.minX - 1, y: bounds.midY)
        case .bottom: CGPoint(x: bounds.midX, y: bounds.maxY + 1)
        case .top: CGPoint(x: bounds.midX, y: bounds.minY - 1)
        }
        let point = outside.applying(CropMath.displayTransform(of: document).inverted())
        return combineEdge(for: point, visible: document.canvas.rect) ?? edge
    }

    // MARK: Canvas size / resize

    /// Visible size as the user sees it (after rotation), pixels.
    var outputContentSize: CGSize { DocumentRenderer.contentSize(of: store.document) }

    /// Canvas size as the user sees it (after rotation), pixels.
    var displayedCanvasSize: CGSize { CropMath.displayBounds(of: store.document).size }

    /// Resize Image: `width × height` as displayed (swapped back for odd
    /// quarter turns).
    func resizeImage(toDisplayed size: CGSize) {
        let (w, h) = Self.canvasAxes(size, turns: store.document.transform.rotationQuarterTurns)
        guard w > 0, h > 0 else { return }
        commitTextEditing?()
        perform(.resizeImage(width: w, height: h))
    }

    /// Canvas Size: `size` and `anchor` as displayed.
    func resizeCanvas(toDisplayed size: CGSize, anchor: BackgroundAlignment) {
        let (w, h) = Self.canvasAxes(size, turns: store.document.transform.rotationQuarterTurns)
        guard w > 0, h > 0 else { return }
        commitTextEditing?()
        let canvasAnchor = Self.canvasAnchor(forDisplayed: anchor, in: store.document)
        perform(.resizeCanvas(width: w, height: h, anchor: canvasAnchor))
    }

    nonisolated static func canvasAxes(_ size: CGSize, turns: Int) -> (Int, Int) {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        return turns % 2 == 1 ? (h, w) : (w, h)
    }

    /// Maps an anchor picked on the rotated / flipped view back to canvas space
    /// (pure, tested).
    nonisolated static func canvasAnchor(forDisplayed anchor: BackgroundAlignment, in document: ProjectDocument) -> BackgroundAlignment {
        guard !document.transform.isIdentity else { return anchor }
        let bounds = CropMath.displayBounds(of: document)
        let point = CGPoint(x: bounds.minX + anchor.horizontal * bounds.width, y: bounds.minY + anchor.vertical * bounds.height)
            .applying(CropMath.displayTransform(of: document).inverted())
        let fx = point.x / max(CGFloat(document.canvas.width), 1)
        let fy = point.y / max(CGFloat(document.canvas.height), 1)
        return BackgroundAlignment.allCases.first { abs($0.horizontal - fx) < 0.01 && abs($0.vertical - fy) < 0.01 } ?? .center
    }

    // MARK: Image sources

    /// Full-resolution image file (EXIF orientation applied), capped at 16384 px.
    nonisolated static func loadFullImage(at url: URL) -> CGImage? {
        loadImage(at: url, maxPixelSize: 16384)
    }

    /// The first image on `pasteboard`: an image file URL, else PNG / TIFF /
    /// other image data. Our own object clipboard is not an image.
    static func image(from pasteboard: NSPasteboard) -> CGImage? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let image = urls.lazy.compactMap({ loadFullImage(at: $0) }).first {
            return image
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier), NSPasteboard.PasteboardType(UTType.heic.identifier)] {
            if let data = pasteboard.data(forType: type), let image = decodeImage(data) { return image }
        }
        return nil
    }

    /// Whether `pasteboard` holds something `image(from:)` can read (cheap).
    static func hasImage(on pasteboard: NSPasteboard) -> Bool {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        return pasteboard.canReadObject(forClasses: [NSURL.self], options: options)
            || pasteboard.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]) != nil
    }

    nonisolated static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
