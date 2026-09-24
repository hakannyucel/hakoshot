@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import os

/// Studio Mode recordings (plan §4.14, §4.18, R6.3): the stopped session
/// folder (`screen.mov` without cursor, Ultra; `events.json`, `cursor.bin`,
/// `cursors/`, optional `camera.mov`) becomes a `.hakostudio` package.
///
/// The fragmented `screen.mov` is remuxed (passthrough, every track kept
/// separate) into a regular QuickTime movie first so the editor seeks
/// quickly; if that fails the raw file is used as is. Media are moved into
/// the package (the session folder is left with nothing the router needs).
/// Auto zooms are planned from the clicks when "Auto zoom on clicks" is on.
/// The preview is the Studio-rendered poster frame (background included),
/// else the raw screen frame.
nonisolated enum StudioRecordingFinalizer {
    struct Output: Sendable {
        var packageURL: URL
        var project: StudioProject
        /// Poster for History / Finder (≤ `previewHeight` px tall).
        var preview: CGImage
    }

    /// Poster frame height (History preview, `preview.png`).
    static let previewHeight = 540

    /// New-project defaults from Settings (`studio*` keys; the default
    /// background is `studioDefaultBackground`, "" = the Studio default).
    @MainActor
    static func defaults(settings: AppSettings) -> StudioProjectDefaults {
        StudioProjectDefaults(
            autoZoom: settings.value(for: .studioAutoZoom),
            defaultZoom: settings.value(for: .studioDefaultZoom),
            cursorSmoothing: settings.value(for: .studioCursorSmoothing),
            motionBlur: settings.value(for: .studioMotionBlur),
            motionBlurIntensity: settings.value(for: .studioMotionBlurIntensity),
            background: background(fromJSON: settings.value(for: .studioDefaultBackground))
        )
    }

    /// `studioDefaultBackground` JSON → style; empty or unreadable = `StudioCanvas.defaultBackground`.
    static func background(fromJSON json: String) -> BackgroundStyle {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              let style = try? JSONDecoder().decode(BackgroundStyle.self, from: data)
        else { return StudioCanvas.defaultBackground }
        return style
    }

    /// Builds the package at `packageURL` from `raw`'s session folder.
    ///
    /// - Parameter metadata: overrides the folder's `events.json` (crash
    ///   recovery passes `RecordingSessionMarker.fallbackMetadata` when there
    ///   is none).
    @concurrent
    static func makePackage(
        from raw: RawRecording,
        metadata: RecordingMetadata? = nil,
        defaults: StudioProjectDefaults,
        at packageURL: URL
    ) async throws -> Output {
        let started = Date.now
        let fm = FileManager.default
        let folder = raw.sessionFolder
        let screenURL = folder.appending(path: RawRecording.FileName.screen)
        await defragment(screenURL)

        let info: RenderSourceInfo
        do {
            info = try await RenderPipeline.probe(screenURL)
        } catch {
            throw RecordingError.finalizeFailed("studio: screen.mov unreadable: \(String(describing: error))")
        }
        guard info.duration > 0 else { throw RecordingError.noFrames }

        var resolvedMetadata = metadata
        if resolvedMetadata == nil, let data = try? Data(contentsOf: folder.appending(path: RawRecording.FileName.events)) {
            resolvedMetadata = try? RecordingMetadata(jsonData: data)
        }
        let hasCamera = fm.fileExists(atPath: folder.appending(path: RawRecording.FileName.camera).path)
        let source = StudioSource(
            pixelWidth: info.pixelWidth,
            pixelHeight: info.pixelHeight,
            pointWidth: raw.pointSize.width > 0 ? raw.pointSize.width : nil,
            pointHeight: raw.pointSize.height > 0 ? raw.pointSize.height : nil,
            // The recording's frame rate: SCK only sends frames on change, so a
            // still screen gives the file a nominal rate far below it.
            fps: raw.fps > 0 ? Double(raw.fps) : info.fps,
            duration: info.duration,
            cursorBakedIn: false,
            audioTracks: audioTrackNames(raw.audioTracks, trackCount: info.audioTrackCount),
            media: StudioMediaFiles(camera: hasCamera ? StudioMediaFiles.defaultCamera : nil)
        )

        try fm.createDirectory(at: packageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var project = try StudioProjectFile.create(
            from: folder, metadata: resolvedMetadata, source: source, defaults: defaults,
            at: packageURL, transfer: .move, createdAt: raw.startDate
        )
        if project.zoom.auto, let resolvedMetadata {
            project.zoom.segments = ZoomPlanner.autoSegments(project: project, metadata: resolvedMetadata)
        }

        let preview = await poster(project: project, packageURL: packageURL)
        try StudioProjectFile.write(project, preview: preview, to: packageURL)
        guard let preview else { throw RecordingError.finalizeFailed("studio: no poster frame") }
        Log.recording.notice("studio package \(packageURL.lastPathComponent, privacy: .public): \(info.pixelWidth)x\(info.pixelHeight) @\(String(format: "%.0f", source.fps), privacy: .public) fps, \(String(format: "%.3f", info.duration), privacy: .public) s, camera \(hasCamera), clicks \(resolvedMetadata?.clicks.count ?? 0), auto zooms \(project.zoom.segments.count), cursorBakedIn \(project.source.cursorBakedIn) in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s")
        return Output(packageURL: packageURL, project: project, preview: preview)
    }

    /// `RecordingResult` for a finished package (DEBUG sidecars, logs).
    static func result(for output: Output, raw: RawRecording) -> RecordingResult {
        let screen = StudioProjectFile.mediaURL(output.project.source.media.screen, in: output.packageURL)
        return RecordingResult(
            fileURL: screen,
            format: .video,
            duration: output.project.source.duration,
            pixelSize: output.project.source.pixelSize,
            thumbnail: output.preview,
            date: raw.startDate,
            targetKind: raw.target.kind,
            studioProjectURL: output.packageURL,
            raw: raw
        )
    }

    // MARK: Steps

    /// Fragmented → regular movie, same tracks (no re-encode). Keeps the raw
    /// file when the remux fails.
    static func defragment(_ url: URL) async {
        let temporary = url.deletingLastPathComponent().appending(path: "screen-remux.mov")
        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: temporary)
            try await session.export(to: temporary, as: .mov)
            _ = try fm.replaceItemAt(url, withItemAt: temporary)
        } catch {
            try? fm.removeItem(at: temporary)
            Log.recording.error("studio: remux of screen.mov failed, using it as is: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Track role names in file order ("microphone", "system").
    static func audioTrackNames(_ kinds: [AudioTrackKind], trackCount: Int) -> [String] {
        if kinds.count == trackCount { return kinds.map(\.rawValue) }
        return RecordingFinalizer.roles(kinds, trackCount: trackCount).map { $0 == .microphone ? "microphone" : "system" }
    }

    /// The Studio frame at the poster time, else the raw screen frame.
    private static func poster(project: StudioProject, packageURL: URL) async -> CGImage? {
        let time = RecordingThumbnailer.posterTime(forDuration: project.timeline.outputDuration)
        let media = StudioMediaContext.load(packageURL: packageURL, project: project)
        if let frame = try? await StudioExport.frameImage(project: project, media: media, outputTime: time, outputHeight: previewHeight) {
            return frame
        }
        let screen = StudioProjectFile.mediaURL(project.source.media.screen, in: packageURL)
        return try? await RecordingThumbnailer.thumbnail(for: screen, at: time)
    }
}
