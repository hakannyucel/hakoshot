import AVFoundation
import Foundation
import HakoKit
import os

/// "Open in Studio" for classic recordings (plan §4.18): wraps an mp4 in a
/// `.hakostudio` package so Studio's background, aspect ratio, zoom and
/// export work on it. The mp4 becomes `media/<its name>` (`media.screen`),
/// an `events.json` next to it (History keeps `<uuid>-events.json`) is
/// carried along for clicks, and `cursorBakedIn = true` (the cursor is in
/// the pixels, so cursor size / smoothing / hiding are inert).
///
/// The package goes next to the History entry
/// (`HistoryLayout.studioPackageName`, `<yyyy-MM>/<uuid>.hakostudio`) or,
/// without one, into `~/Library/Application Support/HakoShot/Studio/`. The
/// mp4 is hard-linked into the package (copied across volumes), never moved.
nonisolated enum StudioDocumentOpener {
    /// History entry the video belongs to.
    struct HistoryPlacement: Sendable {
        var rootURL: URL
        var id: UUID
        var date: Date
        var calendar: Calendar = .current
    }

    enum OpenerError: Error, Equatable, CustomStringConvertible {
        case notAVideo(String)

        var description: String {
            switch self {
            case .notAVideo(let name): "\(name) is not a video HakoShot can open in Studio"
            }
        }
    }

    /// `~/Library/Application Support/HakoShot/Studio/`.
    static var defaultFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "HakoShot/Studio", directoryHint: .isDirectory)
    }

    /// Where the package for `videoURL` goes.
    static func packageURL(for videoURL: URL, history: HistoryPlacement?, folder: URL = defaultFolder) -> URL {
        if let history {
            let name = HistoryLayout.studioPackageName(id: history.id, date: history.date, calendar: history.calendar)
            return history.rootURL.appending(path: name, directoryHint: .isDirectory)
        }
        let base = videoURL.deletingPathExtension().lastPathComponent
        var url = folder.appending(path: "\(base).\(StudioProjectFile.fileExtension)", directoryHint: .isDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) (\(n)).\(StudioProjectFile.fileExtension)", directoryHint: .isDirectory)
            n += 1
        }
        return url
    }

    /// Returns the package for `videoURL`, creating it when needed (an
    /// existing package at the History location is reused).
    ///
    /// - Parameters:
    ///   - eventsURL: recorded `events.json` (clicks for auto zoom), if any.
    ///   - scale: pixels per point of the recording (History item scale).
    @concurrent
    static func makePackage(
        for videoURL: URL,
        eventsURL: URL? = nil,
        history: HistoryPlacement? = nil,
        scale: Double? = nil,
        defaults: StudioProjectDefaults = .standard,
        folder: URL = defaultFolder
    ) async throws -> URL {
        let destination = packageURL(for: videoURL, history: history, folder: folder)
        if history != nil, (try? StudioProjectFile.read(from: destination)) != nil {
            return destination
        }
        let info: RenderSourceInfo
        do {
            info = try await RenderPipeline.probe(videoURL)
        } catch {
            throw OpenerError.notAVideo(videoURL.lastPathComponent)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".studio-open-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let screenName = videoURL.lastPathComponent
        try linkOrCopy(videoURL, to: staging.appending(path: screenName))
        var metadata: RecordingMetadata?
        if let eventsURL, let data = try? Data(contentsOf: eventsURL), var decoded = try? RecordingMetadata(jsonData: data) {
            decoded.cursorBakedIn = true
            metadata = decoded
        }

        let ppp = scale ?? metadata?.geometry.pixelsPerPoint ?? 1
        let k = ppp > 0 && ppp.isFinite ? ppp : 1
        let source = StudioSource(
            pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight,
            pointWidth: Double(info.pixelWidth) / k, pointHeight: Double(info.pixelHeight) / k,
            // `fps` = the highest rate (screen recordings are VFR; a still screen has a tiny nominal rate).
            fps: info.fps > 0 ? info.fps : info.nominalFPS,
            duration: info.duration,
            cursorBakedIn: true,
            audioTracks: info.audioChannelCounts.count == 1 ? ["audio"] : Array(["microphone", "system"].prefix(info.audioTrackCount)),
            media: StudioMediaFiles(screen: screenName, camera: nil, events: nil, cursor: nil, cursorsDirectory: nil)
        )
        var project = try StudioProjectFile.create(
            from: staging, metadata: metadata, source: source, defaults: defaults,
            at: destination, transfer: .move
        )
        // `create` takes cursorBakedIn from the metadata; a classic video always has it baked in.
        project.source.cursorBakedIn = true
        if project.zoom.auto, let metadata {
            project.zoom.segments = ZoomPlanner.regenerated(project: project, metadata: metadata)
        }
        try StudioProjectFile.write(project, to: destination)
        Log.studio.notice("open in studio: \(videoURL.lastPathComponent, privacy: .public) -> \(destination.lastPathComponent, privacy: .public)")
        return destination
    }

    private static func linkOrCopy(_ from: URL, to: URL) throws {
        do {
            try FileManager.default.linkItem(at: from, to: to)
        } catch {
            try FileManager.default.copyItem(at: from, to: to)
        }
    }
}

extension StudioWindowController {
    /// "Open in Studio" for a classic mp4: builds (or reuses) the package,
    /// then opens it.
    @discardableResult
    static func openVideo(
        _ videoURL: URL,
        eventsURL: URL? = nil,
        history: StudioDocumentOpener.HistoryPlacement? = nil,
        scale: Double? = nil
    ) async -> StudioWindowController? {
        do {
            let package = try await StudioDocumentOpener.makePackage(for: videoURL, eventsURL: eventsURL, history: history, scale: scale)
            return open(url: package)
        } catch {
            Log.studio.error("open in studio failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
