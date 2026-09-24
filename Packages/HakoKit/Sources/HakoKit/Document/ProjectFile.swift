import CoreGraphics
import Foundation
import ImageIO

public enum ProjectFileError: Error, Sendable, Equatable {
    /// The URL / wrapper is not a directory package.
    case notAPackage
    /// `project.json` is missing.
    case missingProjectJSON
    /// `project.json` is not valid JSON or does not match the schema.
    case corruptProjectJSON(String)
    /// Written by a newer HakoShot (`formatVersion` > current).
    case unsupportedFormatVersion(Int)
    /// An older version with no migration path.
    case migrationFailed(String)
    /// The document references an asset that is not in the bundle (read) or
    /// not in the supplied images (write).
    case missingAsset(AssetID)
    /// `assets/<id>.png` exists but is not a decodable image.
    case corruptAsset(AssetID)
    /// PNG encoding of an asset failed.
    case encodingFailed(AssetID)
}

/// Reads and writes the `.hakoshot` project package (plan §4.9):
///
/// ```
/// Name.hakoshot/
/// ├── project.json        ProjectDocument, pretty-printed, sorted keys
/// ├── assets/<id>.png     every referenced image, lossless, original pixels
/// └── preview.png         flattened render, longest edge ≤ 1024 px
/// ```
///
/// Only assets referenced by the document are written. `preview.png` is
/// informational (History, Quick Look); readers never require it.
public enum ProjectFile {
    public static let fileExtension = "hakoshot"
    /// Exported UTI (conforms to `com.apple.package`), see `reports/ilerleme.md`.
    public static let typeIdentifier = "com.hakanyucel.hakoshot.project"
    public static let projectFileName = "project.json"
    public static let assetsDirectoryName = "assets"
    public static let previewFileName = "preview.png"
    /// Longest edge of `preview.png`, in pixels.
    public static let previewMaxPixelSize = 1024

    /// A decoded project: the document plus every image it references.
    public struct Contents: @unchecked Sendable {
        // `CGImage` is immutable and thread-safe; the dictionary is a value.
        public var document: ProjectDocument
        public var assets: [AssetID: CGImage]

        public init(document: ProjectDocument, assets: [AssetID: CGImage]) {
            self.document = document
            self.assets = assets
        }
    }

    // MARK: FileWrapper (NSDocument-style)

    /// Builds the package wrapper.
    ///
    /// - Parameters:
    ///   - assets: images by ID; must contain every `document.referencedAssets`
    ///     entry unless `existing` already has its file.
    ///   - existing: the wrapper last read / written for this document. Asset
    ///     files are immutable per ID, so matching `assets/<id>.png` entries are
    ///     reused instead of re-encoded (cheap autosave for large captures).
    ///   - includePreview: render and add `preview.png`.
    public static func fileWrapper(
        for document: ProjectDocument,
        assets: [AssetID: CGImage],
        reusing existing: FileWrapper? = nil,
        includePreview: Bool = true
    ) throws(ProjectFileError) -> FileWrapper {
        let json: Data
        do {
            json = try document.jsonData()
        } catch {
            throw .corruptProjectJSON(String(describing: error))
        }

        let oldAssets = existing?.fileWrappers?[assetsDirectoryName]?.fileWrappers ?? [:]
        let dpi = 72 * max(document.canvas.scale, 1)
        var assetWrappers: [String: FileWrapper] = [:]
        for id in document.referencedAssets.sorted(by: { $0.rawValue < $1.rawValue }) {
            let name = assetFileName(id)
            if let image = assets[id] {
                let data: Data
                do {
                    data = try ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions(dpi: dpi))
                } catch {
                    throw .encodingFailed(id)
                }
                assetWrappers[name] = regularFile(data, named: name)
            } else if let old = oldAssets[name], old.isRegularFile, let data = old.regularFileContents {
                assetWrappers[name] = regularFile(data, named: name)
            } else {
                throw .missingAsset(id)
            }
        }

        var children: [String: FileWrapper] = [
            projectFileName: regularFile(json, named: projectFileName),
        ]
        let assetsDirectory = FileWrapper(directoryWithFileWrappers: assetWrappers)
        assetsDirectory.preferredFilename = assetsDirectoryName
        children[assetsDirectoryName] = assetsDirectory

        if includePreview, let preview = previewImage(for: document, assets: assets, fallback: oldAssets),
           let data = try? ImageEncoder.encode(preview, format: .png, options: ImageEncodeOptions()) {
            children[previewFileName] = regularFile(data, named: previewFileName)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    /// Decodes a package wrapper: migrates `project.json`, then loads every
    /// referenced asset.
    public static func read(from wrapper: FileWrapper) throws(ProjectFileError) -> Contents {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else { throw .notAPackage }
        guard let jsonWrapper = children[projectFileName], jsonWrapper.isRegularFile,
              let json = jsonWrapper.regularFileContents else {
            throw .missingProjectJSON
        }
        let document = try decodeDocument(json)

        let files = children[assetsDirectoryName]?.fileWrappers ?? [:]
        var assets: [AssetID: CGImage] = [:]
        for id in document.referencedAssets {
            guard let file = files[assetFileName(id)], file.isRegularFile, let data = file.regularFileContents else {
                throw .missingAsset(id)
            }
            guard let image = decodeImage(data) else { throw .corruptAsset(id) }
            assets[id] = image
        }
        return Contents(document: document, assets: assets)
    }

    /// Decodes (and migrates) `project.json` data.
    public static func decodeDocument(_ json: Data) throws(ProjectFileError) -> ProjectDocument {
        let upgraded: Data
        do {
            upgraded = try Migration.upgrade(json)
        } catch {
            switch error {
            case .unreadable: throw .corruptProjectJSON("project.json is not a versioned JSON object")
            case .newerVersion(let version): throw .unsupportedFormatVersion(version)
            case .noMigrationPath(let from): throw .migrationFailed("no migration from formatVersion \(from)")
            case .stepFailed(let from, let reason): throw .migrationFailed("step from \(from): \(reason)")
            }
        }
        do {
            return try ProjectDocument(jsonData: upgraded)
        } catch ProjectDocumentError.unsupportedFormatVersion(let version) {
            throw .unsupportedFormatVersion(version)
        } catch {
            throw .corruptProjectJSON(String(describing: error))
        }
    }

    // MARK: URL

    /// Writes the package to `url` atomically: the bundle is assembled in a
    /// temporary directory on the same volume, then swapped in, so an existing
    /// file is either fully replaced or left untouched.
    public static func write(
        _ document: ProjectDocument,
        assets: [AssetID: CGImage],
        to url: URL,
        includePreview: Bool = true
    ) throws {
        var existing: FileWrapper?
        if FileManager.default.fileExists(atPath: url.path) {
            // Lets missing in-memory assets fall back to the file on disk.
            existing = try? FileWrapper(url: url, options: .immediate)
        }
        let wrapper = try fileWrapper(for: document, assets: assets, reusing: existing, includePreview: includePreview)
        try write(wrapper, to: url)
    }

    /// Atomically writes an already built package wrapper to `url`.
    public static func write(_ wrapper: FileWrapper, to url: URL) throws {
        let fm = FileManager.default
        let destination = url.standardizedFileURL
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination, create: true)
        defer { try? fm.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try wrapper.write(to: staged, options: [], originalContentsURL: nil)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
    }

    /// Reads a package from disk.
    public static func read(from url: URL) throws -> Contents {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ProjectFileError.notAPackage
        }
        let wrapper = try FileWrapper(url: url, options: .immediate)
        return try read(from: wrapper)
    }

    /// `preview.png` of a package on disk, if present (History, Quick Look).
    public static func readPreview(from url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(previewFileName)) else { return nil }
        return decodeImage(data)
    }

    // MARK: Preview

    /// Pixel size of `preview.png` for a document: the output size scaled to
    /// fit `previewMaxPixelSize` (never enlarged).
    /// Uses the static output size, which ignores auto-balance; the written
    /// preview is sized from the rendered image instead.
    public static func previewSize(for document: ProjectDocument) -> CGSize {
        fittedPreviewSize(DocumentRenderer.outputSize(of: document))
    }

    static func fittedPreviewSize(_ size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return CGSize(width: 1, height: 1) }
        let factor = min(1, Double(previewMaxPixelSize) / longest)
        return CGSize(width: max(1, (size.width * factor).rounded()), height: max(1, (size.height * factor).rounded()))
    }

    /// Renders the flattened, downscaled preview.
    public static func previewImage(for document: ProjectDocument, assets: [AssetID: CGImage]) -> CGImage? {
        previewImage(for: document, assets: assets, fallback: [:])
    }

    private static func previewImage(
        for document: ProjectDocument,
        assets: [AssetID: CGImage],
        fallback: [String: FileWrapper]
    ) -> CGImage? {
        var resolved = assets
        for id in document.referencedAssets where resolved[id] == nil {
            if let data = fallback[assetFileName(id)]?.regularFileContents, let image = decodeImage(data) {
                resolved[id] = image
            }
        }
        let images = SendableImages(resolved)
        let renderer = DocumentRenderer { images.value[$0] }
        guard let full = renderer.makeImage(document) else { return nil }
        let size = fittedPreviewSize(CGSize(width: full.width, height: full.height))
        if full.width == Int(size.width), full.height == Int(size.height) { return full }
        guard let context = RenderSupport.makeBitmapContext(width: Int(size.width), height: Int(size.height)) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(full, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    // MARK: Helpers

    static func assetFileName(_ id: AssetID) -> String { "\(id.rawValue).png" }

    private static func regularFile(_ data: Data, named name: String) -> FileWrapper {
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        return file
    }

    /// Decodes eagerly so the first draw doesn't pay for PNG decompression.
    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

/// `CGImage` is immutable and thread-safe; wraps the lookup table for the
/// renderer's `@Sendable` resolver.
private struct SendableImages: @unchecked Sendable {
    let value: [AssetID: CGImage]
    init(_ value: [AssetID: CGImage]) { self.value = value }
}
