import AppKit
import CoreGraphics
import HakoKit
import UniformTypeIdentifiers
import os

/// `.hakoshot` project support for the editor (plan §4.9, WP5.3): open a
/// package with every annotation still editable, write it back, and report
/// every save so the app can keep an editable copy in History.
extension EditorViewModel {
    /// Opens a decoded project. `projectURL` is where ⌘S writes the package
    /// (`nil` for history copies: ⌘S then writes `sourceURL` / a new image).
    convenience init?(
        project: ProjectFile.Contents,
        projectURL: URL?,
        sourceURL: URL? = nil,
        historyID: UUID? = nil,
        settings: AppSettings = .shared
    ) {
        let document = project.document
        guard let base = document.layers.first.flatMap({ project.assets[$0.assetID] })
            ?? project.assets.values.first
        else { return nil }
        let mode = document.source.flatMap { CaptureMode(fileNameToken: $0.mode) } ?? .area
        self.init(
            document: document,
            assets: project.assets,
            baseImage: base,
            mode: mode,
            date: document.source?.capturedAt ?? document.createdAt,
            sourceURL: sourceURL,
            settings: settings
        )
        self.projectURL = projectURL
        self.historyID = historyID
    }

    /// The current document with its images (for writing a package).
    var projectContents: ProjectFile.Contents {
        ProjectFile.Contents(document: store.document, assets: assets)
    }

    /// Writes the current document as a `.hakoshot` package (atomic).
    func writeProject(to url: URL) throws {
        commitTextEditing?()
        try ProjectFile.write(store.document, assets: assets, to: url)
    }

    /// Reports a finished save (⌘S, Save As, Done) so History gets the project.
    func didSave(imageURL: URL?) {
        let event = EditorSaveEvent(
            contents: projectContents,
            baseImage: baseImage,
            scale: canvasScale,
            mode: captureMode,
            date: captureDate,
            historyID: historyID,
            imageURL: imageURL
        )
        guard let handler = EditorDocumentEvents.onSaved else { return }
        if let id = handler(event) { historyID = id }
    }
}

/// One editor save, for `EditorDocumentEvents.onSaved`.
nonisolated struct EditorSaveEvent: Sendable {
    var contents: ProjectFile.Contents
    /// Original (un-annotated) bottom layer, for a new history entry.
    var baseImage: CGImage
    var scale: CGFloat
    var mode: CaptureMode
    var date: Date
    /// History entry the editor belongs to; `nil` = none yet.
    var historyID: UUID?
    /// Flat image written by this save (`nil` for project-only saves).
    var imageURL: URL?
}

/// App-wide editor document hooks (set once by `AppCoordinator`).
enum EditorDocumentEvents {
    /// Called after every successful editor save. Returns the history entry id
    /// that now holds the project (created if the editor had none), or `nil`.
    static var onSaved: ((EditorSaveEvent) -> UUID?)?
}

extension ProjectFile {
    /// `UTType` for `.hakoshot` (exported in Info.plist).
    static var contentType: UTType {
        UTType(typeIdentifier) ?? UTType(exportedAs: typeIdentifier, conformingTo: .package)
    }

    /// Whether `url` names a `.hakoshot` package.
    static func isProject(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == fileExtension
    }
}

extension CaptureMode {
    /// Inverse of `fileNameToken` (stored as `source.mode` in projects).
    nonisolated init?(fileNameToken token: String) {
        switch token {
        case "area": self = .area
        case "window": self = .window
        case "fullscreen": self = .fullscreen(.preferred)
        case "previous-area": self = .previousArea
        case "scrolling": self = .scrolling
        case "self-timer": self = .selfTimer
        case "all-in-one": self = .allInOne
        case "text": self = .text
        default: return nil
        }
    }
}
