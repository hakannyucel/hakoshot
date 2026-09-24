import CoreGraphics
import Foundation
import ImageIO

public enum StudioProjectFileError: Error, Sendable, Equatable {
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
    /// A required media file (the screen video, or a file named by the
    /// project) is not in `media/`.
    case missingMedia(String)
    /// A referenced background image is missing.
    case missingAsset(AssetID)
    /// `assets/<id>.png` is not a decodable image.
    case corruptAsset(AssetID)
    /// PNG encoding failed (asset or preview).
    case encodingFailed(String)
    /// Moving / copying / linking files failed.
    case fileOperationFailed(String)
}

/// Upgrades `project.json` of older `.hakostudio` packages to
/// `StudioProject.currentFormatVersion` (same runner and rules as the
/// screenshot `Migration`; see there for how to add a step).
public enum StudioMigration {
    /// Registered upgrades, oldest first. v1 is the first format; none yet.
    public static let steps: [Migration.Step] = []

    /// Returns data at the current version; current data is returned unchanged.
    public static func upgrade(_ data: Data) throws(Migration.Error) -> Data {
        try Migration.upgrade(data, to: StudioProject.currentFormatVersion, steps: steps)
    }

    /// Dispatch with an explicit target and step list (testable).
    static func upgrade(_ data: Data, to target: Int, steps: [Migration.Step]) throws(Migration.Error) -> Data {
        try Migration.upgrade(data, to: target, steps: steps)
    }
}

/// Reads and writes the `.hakostudio` package (plan §4.18):
///
/// ```
/// Demo.hakostudio/
/// ├── project.json          StudioProject, pretty-printed, sorted keys
/// ├── media/                immutable recording (never rewritten)
/// │   ├── screen.mov
/// │   ├── camera.mov        optional
/// │   ├── events.json       RecordingMetadata
/// │   ├── cursor.bin        CursorTrackCodec
/// │   └── cursors/<hash>.png
/// ├── assets/<id>.png       custom background image, if any
/// └── preview.png           ≤ 1024 px (History, Finder); optional
/// ```
///
/// Media files can be gigabytes, so saves never copy them: the URL writer
/// stages the new package next to the destination with `media/` hard-linked
/// (copied only across volumes) and swaps it in atomically; the
/// `FileWrapper` path reuses the previous wrapper's `media` child (NSDocument
/// hard-links unchanged children on save).
public enum StudioProjectFile {
    public static let fileExtension = "hakostudio"
    /// Exported UTI (conforms to `com.apple.package`), plan §4.18.
    public static let typeIdentifier = "com.hakanyucel.hakoshot.studio"
    public static let projectFileName = "project.json"
    public static let mediaDirectoryName = "media"
    public static let assetsDirectoryName = "assets"
    public static let previewFileName = "preview.png"
    public static let previewMaxPixelSize = 1024

    /// A decoded package.
    public struct Contents: @unchecked Sendable {
        // `CGImage` is immutable and thread-safe.
        public var project: StudioProject
        /// Background images by ID.
        public var assets: [AssetID: CGImage]

        public init(project: StudioProject, assets: [AssetID: CGImage] = [:]) {
            self.project = project
            self.assets = assets
        }
    }

    /// Absolute locations of the media inside a package on disk.
    public struct MediaURLs: Sendable, Hashable {
        public var screen: URL
        public var camera: URL?
        public var events: URL?
        public var cursor: URL?
        public var cursorsDirectory: URL?
    }

    /// How `create` takes files out of the raw session folder.
    public enum Transfer: Sendable {
        case move
        case copy
    }

    // MARK: JSON

    /// Decodes (and migrates) `project.json` data.
    public static func decodeProject(_ json: Data) throws(StudioProjectFileError) -> StudioProject {
        let upgraded: Data
        do {
            upgraded = try StudioMigration.upgrade(json)
        } catch {
            switch error {
            case .unreadable: throw .corruptProjectJSON("project.json is not a versioned JSON object")
            case .newerVersion(let version): throw .unsupportedFormatVersion(version)
            case .noMigrationPath(let from): throw .migrationFailed("no migration from formatVersion \(from)")
            case .stepFailed(let from, let reason): throw .migrationFailed("step from \(from): \(reason)")
            }
        }
        do {
            return try StudioProject(jsonData: upgraded)
        } catch StudioProjectError.unsupportedFormatVersion(let version) {
            throw .unsupportedFormatVersion(version)
        } catch {
            throw .corruptProjectJSON(String(describing: error))
        }
    }

    // MARK: FileWrapper (NSDocument-style)

    /// Builds the package wrapper.
    ///
    /// - Parameters:
    ///   - media: the `media/` directory wrapper; `nil` reuses `existing`'s.
    ///   - assets: background images by ID; missing ones fall back to
    ///     `existing`'s `assets/` files.
    ///   - preview: written as `preview.png` (scaled to ≤ 1024 px); `nil`
    ///     keeps `existing`'s preview, if any.
    public static func fileWrapper(
        for project: StudioProject,
        media: FileWrapper? = nil,
        assets: [AssetID: CGImage] = [:],
        preview: CGImage? = nil,
        reusing existing: FileWrapper? = nil
    ) throws(StudioProjectFileError) -> FileWrapper {
        let old = existing?.fileWrappers ?? [:]
        guard let mediaWrapper = media ?? old[mediaDirectoryName], mediaWrapper.isDirectory else {
            throw .missingMedia(mediaDirectoryName)
        }
        let mediaChildren = mediaWrapper.fileWrappers ?? [:]
        guard mediaChildren[project.source.media.screen] != nil else {
            throw .missingMedia(project.source.media.screen)
        }

        var children: [String: FileWrapper] = [
            projectFileName: regularFile(try projectJSON(project), named: projectFileName),
        ]
        mediaWrapper.preferredFilename = mediaDirectoryName
        children[mediaDirectoryName] = mediaWrapper

        let oldAssets = old[assetsDirectoryName]?.fileWrappers ?? [:]
        var assetWrappers: [String: FileWrapper] = [:]
        for id in project.referencedAssets {
            let name = assetFileName(id)
            if let image = assets[id] {
                assetWrappers[name] = regularFile(try encodePNG(image, label: name), named: name)
            } else if let file = oldAssets[name], file.isRegularFile, let data = file.regularFileContents {
                assetWrappers[name] = regularFile(data, named: name)
            } else {
                throw .missingAsset(id)
            }
        }
        if !assetWrappers.isEmpty {
            let directory = FileWrapper(directoryWithFileWrappers: assetWrappers)
            directory.preferredFilename = assetsDirectoryName
            children[assetsDirectoryName] = directory
        }

        if let preview {
            children[previewFileName] = regularFile(try previewPNG(preview), named: previewFileName)
        } else if let oldPreview = old[previewFileName], oldPreview.isRegularFile, let data = oldPreview.regularFileContents {
            children[previewFileName] = regularFile(data, named: previewFileName)
        }
        return FileWrapper(directoryWithFileWrappers: children)
    }

    /// Decodes a package wrapper: migrates `project.json`, checks the screen
    /// video is present, loads background assets. Media is not read.
    public static func read(from wrapper: FileWrapper) throws(StudioProjectFileError) -> Contents {
        guard wrapper.isDirectory, let children = wrapper.fileWrappers else { throw .notAPackage }
        guard let jsonWrapper = children[projectFileName], jsonWrapper.isRegularFile,
              let json = jsonWrapper.regularFileContents else {
            throw .missingProjectJSON
        }
        let project = try decodeProject(json)
        let media = children[mediaDirectoryName]?.fileWrappers ?? [:]
        guard media[project.source.media.screen] != nil else {
            throw .missingMedia(project.source.media.screen)
        }
        let files = children[assetsDirectoryName]?.fileWrappers ?? [:]
        var assets: [AssetID: CGImage] = [:]
        for id in project.referencedAssets {
            guard let file = files[assetFileName(id)], file.isRegularFile, let data = file.regularFileContents else {
                throw .missingAsset(id)
            }
            guard let image = decodeImage(data) else { throw .corruptAsset(id) }
            assets[id] = image
        }
        return Contents(project: project, assets: assets)
    }

    // MARK: URL

    /// Reads a package from disk (media is only checked for presence).
    public static func read(from url: URL) throws(StudioProjectFileError) -> Contents {
        guard isDirectory(url) else { throw .notAPackage }
        let jsonURL = url.appendingPathComponent(projectFileName)
        guard let json = try? Data(contentsOf: jsonURL) else { throw .missingProjectJSON }
        let project = try decodeProject(json)
        let screen = mediaURL(project.source.media.screen, in: url)
        guard FileManager.default.fileExists(atPath: screen.path) else {
            throw .missingMedia(project.source.media.screen)
        }
        var assets: [AssetID: CGImage] = [:]
        for id in project.referencedAssets {
            let assetURL = url.appendingPathComponent(assetsDirectoryName).appendingPathComponent(assetFileName(id))
            guard let data = try? Data(contentsOf: assetURL) else { throw .missingAsset(id) }
            guard let image = decodeImage(data) else { throw .corruptAsset(id) }
            assets[id] = image
        }
        return Contents(project: project, assets: assets)
    }

    /// Saves `project` to `url` atomically.
    ///
    /// The new package is staged next to `url` (same volume): `project.json`,
    /// `assets/`, `preview.png` are written, `media/` is hard-linked from
    /// `mediaSource` (default: `url`'s own `media/`), then the stage replaces
    /// `url` in one step. An existing package is fully replaced or untouched.
    ///
    /// - Parameters:
    ///   - assets: background images; missing ones are taken from the package
    ///     already at `url`.
    ///   - preview: `nil` keeps the existing `preview.png`, if any.
    ///   - mediaSource: a `media/` folder to use instead of the existing one
    ///     ("Save As" to a new location).
    public static func write(
        _ project: StudioProject,
        assets: [AssetID: CGImage] = [:],
        preview: CGImage? = nil,
        to url: URL,
        mediaSource: URL? = nil
    ) throws(StudioProjectFileError) {
        let destination = url.standardizedFileURL
        let media = (mediaSource ?? destination.appendingPathComponent(mediaDirectoryName)).standardizedFileURL
        guard isDirectory(media) else { throw .missingMedia(mediaDirectoryName) }
        guard FileManager.default.fileExists(atPath: media.appendingPathComponent(project.source.media.screen).path) else {
            throw .missingMedia(project.source.media.screen)
        }
        let json = try projectJSON(project)
        var assetData: [String: Data] = [:]
        for id in project.referencedAssets {
            let name = assetFileName(id)
            if let image = assets[id] {
                assetData[name] = try encodePNG(image, label: name)
            } else if let data = try? Data(contentsOf: destination.appendingPathComponent(assetsDirectoryName)
                .appendingPathComponent(name)) {
                assetData[name] = data
            } else {
                throw .missingAsset(id)
            }
        }
        let previewData: Data? = if let preview { try previewPNG(preview) } else {
            try? Data(contentsOf: destination.appendingPathComponent(previewFileName))
        }

        try stage(at: destination) { staged throws(StudioProjectFileError) in
            try linkOrCopy(media, to: staged.appendingPathComponent(mediaDirectoryName, isDirectory: true))
            try writeData(json, to: staged.appendingPathComponent(projectFileName))
            if !assetData.isEmpty {
                let dir = staged.appendingPathComponent(assetsDirectoryName, isDirectory: true)
                try createDirectory(dir)
                for (name, data) in assetData {
                    try writeData(data, to: dir.appendingPathComponent(name))
                }
            }
            if let previewData {
                try writeData(previewData, to: staged.appendingPathComponent(previewFileName))
            }
        }
    }

    /// Builds a new package at `packageURL` from a RawRecording session folder
    /// (`screen.mov`, optional `camera.mov`, `events.json`, `cursor.bin`,
    /// `cursors/`) and returns its project.
    ///
    /// Files named by `source.media` are moved (or copied) into `media/`;
    /// optional ones that don't exist are dropped from the project. If the
    /// folder has no `events.json` but `metadata` is given, it is written.
    /// `cursorBakedIn` comes from the metadata (the folder's `events.json`
    /// when `metadata` is `nil`); with no metadata at all the cursor counts
    /// as baked in (classic recording). On failure, moved files are put back.
    public static func create(
        from rawSessionFolder: URL,
        metadata: RecordingMetadata? = nil,
        source: StudioSource,
        defaults: StudioProjectDefaults = .standard,
        preview: CGImage? = nil,
        at packageURL: URL,
        transfer: Transfer = .move,
        createdAt: Date = Date()
    ) throws(StudioProjectFileError) -> StudioProject {
        let fm = FileManager.default
        let folder = rawSessionFolder.standardizedFileURL
        guard isDirectory(folder) else { throw .notAPackage }
        func exists(_ name: String?) -> String? {
            guard let name, fm.fileExists(atPath: folder.appendingPathComponent(name).path) else { return nil }
            return name
        }
        let wanted = source.media
        guard exists(wanted.screen) != nil else { throw .missingMedia(wanted.screen) }

        var media = StudioMediaFiles(
            screen: wanted.screen,
            camera: exists(wanted.camera),
            events: exists(wanted.events),
            cursor: exists(wanted.cursor),
            cursorsDirectory: exists(wanted.cursorsDirectory)
        )
        var resolvedMetadata = metadata
        if resolvedMetadata == nil, let events = media.events,
           let data = try? Data(contentsOf: folder.appendingPathComponent(events)) {
            resolvedMetadata = try? RecordingMetadata(jsonData: data)
        }
        var writtenEvents: Data?
        if media.events == nil, let metadata {
            do {
                writtenEvents = try metadata.jsonData()
            } catch {
                throw .encodingFailed(RecordingMetadata.fileName)
            }
            media.events = wanted.events ?? StudioMediaFiles.defaultEvents
        }

        var finalSource = source
        finalSource.media = media
        finalSource.cursorBakedIn = resolvedMetadata?.cursorBakedIn ?? true
        if let geometry = resolvedMetadata?.geometry, geometry.width > 0, geometry.height > 0 {
            finalSource.pointWidth = geometry.width
            finalSource.pointHeight = geometry.height
        }
        var project = StudioProject(source: finalSource, defaults: defaults, createdAt: createdAt)
        // Keys were recorded only when the badge was on while recording.
        if let keys = resolvedMetadata?.keys, !keys.isEmpty { project.keystrokes.visible = true }
        let json = try projectJSON(project)
        let previewData: Data? = if let preview { try previewPNG(preview) } else { nil }

        let destination = packageURL.standardizedFileURL
        let names = [media.screen, media.camera, media.cursor, media.cursorsDirectory].compactMap { $0 }
            + (writtenEvents == nil ? [media.events].compactMap { $0 } : [])
        var moved: [(from: URL, to: URL)] = []
        try stage(at: destination, rollback: {
            // Put moved files back before the scratch directory is removed.
            for item in moved.reversed() {
                try? fm.moveItem(at: item.to, to: item.from)
            }
        }) { staged throws(StudioProjectFileError) in
            let mediaDir = staged.appendingPathComponent(mediaDirectoryName, isDirectory: true)
            try createDirectory(mediaDir)
            for name in names {
                let from = folder.appendingPathComponent(name)
                let to = mediaDir.appendingPathComponent(name)
                do {
                    switch transfer {
                    case .move:
                        try fm.moveItem(at: from, to: to)
                        moved.append((from, to))
                    case .copy:
                        try fm.copyItem(at: from, to: to)
                    }
                } catch {
                    throw .fileOperationFailed("\(name): \(error.localizedDescription)")
                }
            }
            if let writtenEvents, let events = media.events {
                try writeData(writtenEvents, to: mediaDir.appendingPathComponent(events))
            }
            try writeData(json, to: staged.appendingPathComponent(projectFileName))
            if let previewData {
                try writeData(previewData, to: staged.appendingPathComponent(previewFileName))
            }
        }
        return project
    }

    // MARK: Media access

    public static func mediaURL(_ name: String, in packageURL: URL) -> URL {
        packageURL.appendingPathComponent(mediaDirectoryName, isDirectory: true).appendingPathComponent(name)
    }

    public static func mediaURLs(for project: StudioProject, in packageURL: URL) -> MediaURLs {
        let m = project.source.media
        return MediaURLs(
            screen: mediaURL(m.screen, in: packageURL),
            camera: m.camera.map { mediaURL($0, in: packageURL) },
            events: m.events.map { mediaURL($0, in: packageURL) },
            cursor: m.cursor.map { mediaURL($0, in: packageURL) },
            cursorsDirectory: m.cursorsDirectory.map { mediaURL($0, in: packageURL) }
        )
    }

    /// `events.json` of a package, `nil` when absent or unreadable.
    public static func readMetadata(for project: StudioProject, in packageURL: URL) -> RecordingMetadata? {
        guard let url = mediaURLs(for: project, in: packageURL).events,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? RecordingMetadata(jsonData: data)
    }

    /// `cursor.bin` samples of a package; empty when absent or unreadable.
    public static func readCursorTrack(for project: StudioProject, in packageURL: URL) -> [CursorSample] {
        guard let url = mediaURLs(for: project, in: packageURL).cursor,
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return (try? CursorTrackCodec.decode(data)) ?? []
    }

    /// `preview.png` of a package on disk, if present.
    public static func readPreview(from url: URL) -> CGImage? {
        guard let data = try? Data(contentsOf: url.appendingPathComponent(previewFileName)) else { return nil }
        return decodeImage(data)
    }

    // MARK: Helpers

    static func assetFileName(_ id: AssetID) -> String { "\(id.rawValue).png" }

    private static func projectJSON(_ project: StudioProject) throws(StudioProjectFileError) -> Data {
        do {
            return try project.jsonData()
        } catch {
            throw .corruptProjectJSON(String(describing: error))
        }
    }

    private static func encodePNG(_ image: CGImage, label: String) throws(StudioProjectFileError) -> Data {
        do {
            return try ImageEncoder.encode(image, format: .png, options: ImageEncodeOptions())
        } catch {
            throw .encodingFailed(label)
        }
    }

    /// PNG of `image` scaled to fit `previewMaxPixelSize` (never enlarged).
    static func previewPNG(_ image: CGImage) throws(StudioProjectFileError) -> Data {
        let longest = max(image.width, image.height)
        var scaled = image
        if longest > previewMaxPixelSize {
            let factor = Double(previewMaxPixelSize) / Double(longest)
            let w = max(1, Int((Double(image.width) * factor).rounded()))
            let h = max(1, Int((Double(image.height) * factor).rounded()))
            if let context = RenderSupport.makeBitmapContext(width: w, height: h) {
                context.interpolationQuality = .high
                context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                if let made = context.makeImage() { scaled = made }
            }
        }
        return try encodePNG(scaled, label: previewFileName)
    }

    private static func regularFile(_ data: Data, named name: String) -> FileWrapper {
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = name
        return file
    }

    private static func decodeImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var flag: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
    }

    private static func createDirectory(_ url: URL) throws(StudioProjectFileError) {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw .fileOperationFailed(error.localizedDescription)
        }
    }

    private static func writeData(_ data: Data, to url: URL) throws(StudioProjectFileError) {
        do {
            try data.write(to: url)
        } catch {
            throw .fileOperationFailed(error.localizedDescription)
        }
    }

    /// Hard-links a file or directory tree; copies when linking fails
    /// (different volume).
    private static func linkOrCopy(_ from: URL, to: URL) throws(StudioProjectFileError) {
        let fm = FileManager.default
        do {
            try fm.linkItem(at: from, to: to)
        } catch {
            try? fm.removeItem(at: to)
            do {
                try fm.copyItem(at: from, to: to)
            } catch {
                throw .fileOperationFailed(error.localizedDescription)
            }
        }
    }

    /// Builds the package in a scratch directory on `destination`'s volume
    /// with `body`, then moves it into place (replacing an existing item).
    private static func stage(
        at destination: URL,
        rollback: () -> Void = {},
        _ body: (URL) throws(StudioProjectFileError) -> Void
    ) throws(StudioProjectFileError) {
        let fm = FileManager.default
        let scratch: URL
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: destination, create: true)
        } catch {
            throw .fileOperationFailed(error.localizedDescription)
        }
        defer { try? fm.removeItem(at: scratch) }
        let staged = scratch.appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        do throws(StudioProjectFileError) {
            try createDirectory(staged)
            try body(staged)
            do {
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: staged)
                } else {
                    try fm.moveItem(at: staged, to: destination)
                }
            } catch {
                throw StudioProjectFileError.fileOperationFailed(error.localizedDescription)
            }
        } catch {
            rollback()
            throw error
        }
    }
}
