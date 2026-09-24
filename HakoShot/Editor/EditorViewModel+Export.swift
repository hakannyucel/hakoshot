import AppKit
import CoreGraphics
import HakoKit
import UniformTypeIdentifiers
import os

/// Copy / Save / Save As / drag data for the editor (plan §4.11).
extension EditorViewModel {
    /// The exported image (crop/transform applied; same renderer as the canvas).
    func renderImage() -> CGImage? {
        commitTextEditing?()
        return renderer.makeImage(store.document)
    }

    /// Points size of `image` at the capture scale (for DPI / pins).
    func pointSize(of image: CGImage) -> CGSize {
        CGSize(width: CGFloat(image.width) / canvasScale, height: CGFloat(image.height) / canvasScale)
    }

    /// ⇧⌘C, or ⌘C with nothing selected.
    @discardableResult
    func copyImageToClipboard() -> Bool {
        guard let image = renderImage() else { return fail("render failed") }
        do {
            try ClipboardWriter().write(image)
            showStatus("Copied to clipboard")
            return true
        } catch {
            return fail("copy failed: \(error)")
        }
    }

    /// ⌘S. Writes the open `.hakoshot` project when there is one; otherwise
    /// updates the image the editor came from (or the last save) in place, or
    /// writes a new file into the configured folder via `OutputService`.
    /// Every save also refreshes the editable copy in History (`didSave`).
    @discardableResult
    func save() -> Bool {
        if let projectURL {
            do {
                try writeProject(to: projectURL)
            } catch {
                return fail("project save failed: \(error)")
            }
            store.markSaved()
            refreshMirrors()
            showStatus("Saved \(projectURL.lastPathComponent)")
            Self.log.notice("saved project \(projectURL.lastPathComponent, privacy: .public), \(self.store.document.annotations.count) annotations")
            didSave(imageURL: nil)
            return true
        }
        guard let image = renderImage() else { return fail("render failed") }
        do {
            if let target = saveTarget {
                let format = Self.format(forExtension: target.pathExtension) ?? .png
                try encode(image, format: format).write(to: target, options: .atomic)
                saveTarget = target
            } else {
                let result = CaptureResult(
                    image: image,
                    pointSize: pointSize(of: image),
                    scale: canvasScale,
                    mode: captureMode,
                    date: .now
                )
                saveTarget = try OutputService(settings: settings).save(result)
            }
            store.markSaved()
            refreshMirrors()
            showStatus("Saved to \(saveTarget?.deletingLastPathComponent().lastPathComponent ?? "disk")")
            Self.log.notice("saved \(self.saveTarget?.lastPathComponent ?? "?", privacy: .public)")
            didSave(imageURL: saveTarget)
            return true
        } catch {
            return fail("save failed: \(error)")
        }
    }

    /// Whether ⌘S knows where to write without asking.
    var hasSaveDestination: Bool { projectURL != nil || saveTarget != nil }

    /// ⇧⌘S: save panel with a format picker (image formats + "HakoShot
    /// Project"), as a sheet on `window`.
    func saveAs(from window: NSWindow?, completion: @escaping (Bool) -> Void = { _ in }) {
        commitTextEditing?()
        let defaultFormat = settings.value(for: .outputImageFormat)
        let initial: SaveAsFormat = projectURL != nil
            ? .project
            : .image(defaultFormat.isSupported ? defaultFormat : .png)
        let accessory = SaveAsFormatAccessory(initial: initial)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.accessoryView = accessory.view
        accessory.panel = panel
        let current = projectURL ?? saveTarget
        let folder = current?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath, isDirectory: true)
        panel.directoryURL = folder
        panel.nameFieldStringValue = current.map { $0.deletingPathExtension().lastPathComponent + "." + accessory.format.fileExtension }
            ?? FileNamer(
                template: FileNameTemplate(pattern: settings.value(for: .outputFileNameTemplate)),
                pathExtension: accessory.format.fileExtension
            ).fileName(counter: FileNameCounter.peek(settings: settings), mode: captureMode.fileNameToken)
        accessory.apply()

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            let saved = self.save(as: accessory.format, to: url)
            // A new file named from the template used the next `%n` value.
            if saved, current == nil {
                _ = FileNameCounter.take(pattern: self.settings.value(for: .outputFileNameTemplate), settings: self.settings)
            }
            completion(saved)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            handler(panel.runModal())
        }
    }

    /// Save As without a panel (also used by DEBUG automation). Afterwards ⌘S
    /// keeps writing to `url` in the same format.
    @discardableResult
    func save(as format: SaveAsFormat, to url: URL) -> Bool {
        do {
            switch format {
            case .project:
                try writeProject(to: url)
                projectURL = url
            case .image(let imageFormat):
                guard let image = renderImage() else { return fail("render failed") }
                try encode(image, format: imageFormat).write(to: url, options: .atomic)
                saveTarget = url
                projectURL = nil
            }
        } catch {
            return fail("save as failed: \(error)")
        }
        store.markSaved()
        refreshMirrors()
        showStatus("Saved \(url.lastPathComponent)")
        Self.log.notice("saved as \(url.lastPathComponent, privacy: .public), \(self.store.document.annotations.count) annotations")
        didSave(imageURL: format == .project ? nil : url)
        return true
    }

    /// PNG bytes + file name for "Drag Me".
    func dragPayload() -> (image: CGImage, data: Data, fileName: String)? {
        guard let image = renderImage(), let data = try? encode(image, format: .png) else { return nil }
        let name = saveTarget.map { $0.deletingPathExtension().lastPathComponent + ".png" }
            ?? FileNamer(
                template: FileNameTemplate(pattern: settings.value(for: .outputFileNameTemplate)),
                pathExtension: ImageFormat.png.fileExtension
            ).fileName(mode: captureMode.fileNameToken)
        return (image, data, name)
    }

    // MARK: Helpers

    func encode(_ image: CGImage, format: ImageFormat) throws -> Data {
        let options = ImageEncodeOptions(
            compressionQuality: CGFloat(settings.outputQuality(for: format)),
            dpi: 72 * canvasScale
        )
        return try ImageEncoder.encode(image, format: format, options: options)
    }

    static func format(forExtension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "webp": .webp
        default: nil
        }
    }

    private func fail(_ message: String) -> Bool {
        Self.log.error("\(message, privacy: .public)")
        showStatus("Something went wrong")
        NSSound.beep()
        return false
    }
}

/// What Save As writes.
enum SaveAsFormat: Equatable {
    case image(ImageFormat)
    /// Editable `.hakoshot` package.
    case project

    var fileExtension: String {
        switch self {
        case .image(let format): format.fileExtension
        case .project: ProjectFile.fileExtension
        }
    }

    var contentType: UTType {
        switch self {
        case .image(let format): UTType(filenameExtension: format.fileExtension) ?? .png
        case .project: ProjectFile.contentType
        }
    }

    var title: String {
        switch self {
        case .image(.png): "PNG"
        case .image(.jpeg): "JPEG"
        case .image(.heic): "HEIC"
        case .image(.webp): "WebP"
        case .project: "HakoShot Project"
        }
    }
}

/// Format pop-up for the Save As panel; keeps the name's extension in sync.
final class SaveAsFormatAccessory: NSObject {
    let view: NSView
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formats: [SaveAsFormat] = ImageFormat.allCases.filter(\.isSupported).map(SaveAsFormat.image) + [.project]
    weak var panel: NSSavePanel?

    var format: SaveAsFormat {
        let index = popup.indexOfSelectedItem
        return formats.indices.contains(index) ? formats[index] : .image(.png)
    }

    init(initial: SaveAsFormat) {
        let label = NSTextField(labelWithString: "Format:")
        let stack = NSStackView(views: [label, popup])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 16)
        view = stack
        super.init()
        popup.addItems(withTitles: formats.map(\.title))
        if let index = formats.firstIndex(of: initial) { popup.selectItem(at: index) }
        popup.target = self
        popup.action = #selector(formatChanged)
    }

    func apply() {
        guard let panel else { return }
        panel.allowedContentTypes = [format.contentType]
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = base + "." + format.fileExtension
    }

    @objc private func formatChanged() {
        apply()
    }
}
