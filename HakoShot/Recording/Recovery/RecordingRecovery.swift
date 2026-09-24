@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import os

/// Crash recovery (kayit-teknik-plan §4.22, R7.4).
///
/// At launch every folder under the sessions root
/// (`~/Library/Application Support/HakoShot/Recordings/<uuid>/`) is a session
/// the app did not get to finish: `RecordingOutputRouter` / `discard()` delete
/// the folder when a recording ends normally. `screen.mov` is a fragmented
/// QuickTime movie (a fragment every 2 s), so after a
/// crash everything up to the last fragment is readable.
///
/// For each folder that is not excluded (the active session) and not still
/// being written:
/// - readable `screen.mov` → `RecordingFinalizer` (remux to mp4) → History
///   (`HistoryStore.addRecording`; History off → the mp4 moves to
///   `fallbackFolder`) → folder deleted;
/// - no / empty / unreadable `screen.mov`, or finalize failed → deleted when
///   the folder's newest file is older than `maxUnreadableAge`, else kept for
///   a later launch.
///
/// Studio sessions (`session.json` profile `studio`; older folders without
/// it: events.json `cursorBakedIn == false` or a `camera.mov`) become a
/// `.hakostudio` package (History `.studio` entry, else the Studio folder)
/// like a normal Studio stop. After a crash during recording `events.json`
/// does not exist (the engine writes it at stop), so the geometry comes from
/// `session.json` and there are no clicks; `cursor.bin` keeps every complete
/// record. If the package fails, the session is recovered as classic mp4.
///
/// Never throws and never crashes on corrupt input; every step is logged
/// (`Log.recording`, "recovery:").
nonisolated enum RecordingRecovery {
    /// Unreadable / empty session folders older than this are deleted.
    static let defaultMaxUnreadableAge: TimeInterval = 24 * 3600
    /// Folders whose files changed more recently than this are skipped (a
    /// session that is starting right now but is not in `excluding` yet).
    static let defaultMinimumIdle: TimeInterval = 15

    /// Scans `sessionsRoot` and recovers what it can (see the type comment).
    /// - Parameters:
    ///   - excluding: session ids (folder names) to leave alone, e.g.
    ///     `RecordingEngine.currentHandle?.id`.
    ///   - fallbackFolder: where the mp4 goes when History does not take it.
    ///   - now: injectable clock (tests).
    static func recover(
        sessionsRoot: URL = RecordingEngine.defaultSessionsRoot,
        excluding: Set<UUID> = [],
        historyStore: HistoryStore,
        audio: AudioMixSettings = .standard,
        fallbackFolder: URL = RecordingOutputRouter.defaultRetainedFolder,
        studioDefaults: StudioProjectDefaults = .standard,
        studioFolder: URL = StudioDocumentOpener.defaultFolder,
        maxUnreadableAge: TimeInterval = defaultMaxUnreadableAge,
        minimumIdle: TimeInterval = defaultMinimumIdle,
        now: Date = .now
    ) async -> RecoveryReport {
        var report = RecoveryReport()
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsRoot.path) else { return report }
        let folders: [URL]
        do {
            folders = try fileManager.contentsOfDirectory(
                at: sessionsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.recording.error("recovery: listing \(sessionsRoot.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return report
        }

        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard isDirectory else { continue }
            guard let id = UUID(uuidString: folder.lastPathComponent) else {
                Log.recording.notice("recovery: skipping \(folder.lastPathComponent, privacy: .public) (not a session folder)")
                continue
            }
            if excluding.contains(id) {
                report.skipped.append(folder)
                Log.recording.notice("recovery: skipping active session \(id.uuidString, privacy: .public)")
                continue
            }
            let lastChange = newestModification(in: folder) ?? .distantPast
            if now.timeIntervalSince(lastChange) < minimumIdle {
                report.skipped.append(folder)
                Log.recording.notice("recovery: skipping \(id.uuidString, privacy: .public) (changed \(String(format: "%.1f", now.timeIntervalSince(lastChange)), privacy: .public) s ago)")
                continue
            }

            if let recovered = await recoverSession(
                id: id, folder: folder, historyStore: historyStore, audio: audio, fallbackFolder: fallbackFolder,
                studio: StudioOptions(defaults: studioDefaults, folder: studioFolder)
            ) {
                report.recovered.append(recovered)
                removeFolder(folder)
                continue
            }

            // Nothing usable: delete once it is old enough, else keep for a later launch.
            let age = now.timeIntervalSince(lastChange)
            if age > maxUnreadableAge {
                removeFolder(folder)
                report.deleted.append(folder)
                Log.recording.notice("recovery: deleted unusable session \(id.uuidString, privacy: .public) (\(Int(age / 3600)) h old)")
            } else {
                report.kept.append(folder)
                Log.recording.notice("recovery: kept unusable session \(id.uuidString, privacy: .public) (\(Int(age / 60)) min old)")
            }
        }
        Log.recording.notice("recovery: \(report.recovered.count) recovered, \(report.deleted.count) deleted, \(report.kept.count) kept, \(report.skipped.count) skipped")
        return report
    }

    /// Launch entry point: runs `recover` off the main actor and calls
    /// `completion` on the main actor with the report (R7.I shows
    /// `report.message` as a toast when it is non-nil).
    @MainActor
    static func recoverAtLaunch(
        sessionsRoot: URL = RecordingEngine.defaultSessionsRoot,
        excluding: Set<UUID> = [],
        historyStore: HistoryStore,
        audio: AudioMixSettings = .standard,
        studioDefaults: StudioProjectDefaults = .standard,
        completion: @escaping @MainActor (RecoveryReport) -> Void
    ) {
        Task.detached(priority: .utility) {
            let report = await recover(
                sessionsRoot: sessionsRoot, excluding: excluding, historyStore: historyStore, audio: audio,
                studioDefaults: studioDefaults
            )
            await MainActor.run { completion(report) }
        }
    }

    // MARK: One session

    struct StudioOptions: Sendable {
        var defaults: StudioProjectDefaults
        var folder: URL
    }

    private static func recoverSession(
        id: UUID,
        folder: URL,
        historyStore: HistoryStore,
        audio: AudioMixSettings,
        fallbackFolder: URL,
        studio: StudioOptions
    ) async -> RecoveredRecording? {
        let fileManager = FileManager.default
        let screenURL = folder.appending(path: RawRecording.FileName.screen)
        let size = ((try? fileManager.attributesOfItem(atPath: screenURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            Log.recording.notice("recovery: \(id.uuidString, privacy: .public) has no screen.mov data")
            return nil
        }
        guard let probe = await probe(screenURL) else {
            Log.recording.error("recovery: \(id.uuidString, privacy: .public) screen.mov (\(size) bytes) is not readable")
            return nil
        }

        let metadata = readMetadata(in: folder)
        let marker = RecordingSessionMarker.read(inSessionFolder: folder)
        let isStudio = Self.isStudioSession(
            marker: marker, metadata: metadata,
            hasCamera: fileManager.fileExists(atPath: folder.appending(path: RawRecording.FileName.camera).path)
        )

        let raw = rawRecording(id: id, folder: folder, screenURL: screenURL, probe: probe, metadata: metadata, marker: marker, isStudio: isStudio)
        if isStudio {
            Log.recording.notice("recovery: \(id.uuidString, privacy: .public) is a Studio session; making a .hakostudio")
            if let recovered = await recoverStudio(
                id: id, raw: raw, metadata: metadata ?? marker?.fallbackMetadata, historyStore: historyStore, studio: studio
            ) {
                return recovered
            }
            guard fileManager.fileExists(atPath: screenURL.path) else { return nil }
            Log.recording.notice("recovery: \(id.uuidString, privacy: .public) Studio package failed; recovering it as classic video")
        }
        var result: RecordingResult
        do {
            result = try await RecordingFinalizer.finalize(raw, audio: audio)
        } catch {
            Log.recording.error("recovery: finalize \(id.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            try? fileManager.removeItem(at: folder.appending(path: RecordingFinalizer.outputFileName))
            return nil
        }
        guard result.duration > 0 else {
            Log.recording.error("recovery: \(id.uuidString, privacy: .public) finalized to an empty file")
            return nil
        }

        let item = await historyStore.addRecording(result)
        if let item, let stored = historyStore.mediaURL(for: item) {
            result.fileURL = stored
            result.historyID = item.id
        } else {
            // History off / failed: keep the mp4 outside the session folder.
            let destination = fallbackFolder.appending(path: "Recovered \(id.uuidString).mp4")
            do {
                try fileManager.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.moveItem(at: result.fileURL, to: destination)
                result.fileURL = destination
            } catch {
                Log.recording.error("recovery: keeping \(id.uuidString, privacy: .public) outside History failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        // The session folder is deleted next.
        result.raw = nil
        Log.recording.notice("recovery: recovered \(id.uuidString, privacy: .public): \(String(format: "%.3f", result.duration), privacy: .public) s → \(result.fileURL.path, privacy: .public)")
        return RecoveredRecording(sessionID: id, result: result, historyItem: item, wasStudio: isStudio)
    }

    /// Studio session → `.hakostudio` (History entry, else `studio.folder`).
    private static func recoverStudio(
        id: UUID,
        raw: RawRecording,
        metadata: RecordingMetadata?,
        historyStore: HistoryStore,
        studio: StudioOptions
    ) async -> RecoveredRecording? {
        let entryID = UUID()
        let historyURL = await historyStore.newStudioPackageURL(id: entryID, date: raw.startDate)
        let packageURL = historyURL ?? RecordingOutputRouter.studioFallbackURL(date: raw.startDate, folder: studio.folder)
        let output: StudioRecordingFinalizer.Output
        do {
            output = try await StudioRecordingFinalizer.makePackage(from: raw, metadata: metadata, defaults: studio.defaults, at: packageURL)
        } catch {
            Log.recording.error("recovery: studio package \(id.uuidString, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        var item: HistoryItem?
        if historyURL != nil {
            item = await historyStore.addStudioProject(
                id: entryID, date: raw.startDate, preview: output.preview, pixelSize: output.project.source.pixelSize,
                scale: Double(raw.scale), duration: output.project.source.duration
            )
        }
        var result = StudioRecordingFinalizer.result(for: output, raw: raw)
        result.historyID = item?.id
        // The session folder is deleted next.
        result.raw = nil
        Log.recording.notice("recovery: recovered studio \(id.uuidString, privacy: .public): \(String(format: "%.3f", result.duration), privacy: .public) s → \(packageURL.path, privacy: .public)")
        return RecoveredRecording(sessionID: id, result: result, historyItem: item, wasStudio: true, studioPackageURL: packageURL)
    }

    /// `session.json` decides; folders from before it: events.json without a
    /// baked-in cursor, or a `camera.mov` (only Studio writes one).
    static func isStudioSession(marker: RecordingSessionMarker?, metadata: RecordingMetadata?, hasCamera: Bool) -> Bool {
        if let marker { return marker.profile == .studio && marker.format == .video }
        return metadata.map { !$0.cursorBakedIn } == true || hasCamera
    }

    /// What the raw file says about itself; `nil` when AVFoundation cannot
    /// read it, it has no video track or no media.
    struct Probe: Sendable, Equatable {
        var duration: Double
        var pixelSize: CGSize
        var fps: Double
        var audioTrackCount: Int
    }

    static func probe(_ url: URL) async -> Probe? {
        let asset = AVURLAsset(url: url)
        do {
            guard try await asset.load(.isReadable) else { return nil }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { return nil }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
            let (natural, transform, fps) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let size = natural.applying(transform)
            let audio = try await asset.loadTracks(withMediaType: .audio).count
            return Probe(
                duration: duration,
                pixelSize: CGSize(width: abs(size.width), height: abs(size.height)),
                fps: Double(fps),
                audioTrackCount: audio
            )
        } catch {
            Log.recording.error("recovery: reading \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Helpers

    private static func readMetadata(in folder: URL) -> RecordingMetadata? {
        let url = folder.appending(path: RawRecording.FileName.events)
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try RecordingMetadata(jsonData: data)
        } catch {
            Log.recording.error("recovery: events.json unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// The `RawRecording` the finalizer needs, rebuilt from the file (and
    /// events.json when the crash happened after stop).
    private static func rawRecording(
        id: UUID, folder: URL, screenURL: URL, probe: Probe, metadata: RecordingMetadata?,
        marker: RecordingSessionMarker?, isStudio: Bool
    ) -> RawRecording {
        let geometryInfo = metadata?.geometry ?? marker?.fallbackMetadata.geometry
        let scale = CGFloat(geometryInfo.map { $0.scale } ?? 1)
        let pointSize: CGSize
        let target: RecordingTarget
        if let geometry = geometryInfo, geometry.width > 0, geometry.height > 0 {
            pointSize = CGSize(width: geometry.width, height: geometry.height)
            target = .area(
                GlobalRect(x: geometry.x, y: geometry.y, width: geometry.width, height: geometry.height),
                displayID: geometry.displayID
            )
        } else {
            let safeScale = scale > 0 ? scale : 1
            pointSize = CGSize(width: probe.pixelSize.width / safeScale, height: probe.pixelSize.height / safeScale)
            target = .area(GlobalRect(x: 0, y: 0, width: pointSize.width, height: pointSize.height), displayID: CGMainDisplayID())
        }
        let startDate = marker?.startDate ?? creationDate(of: screenURL) ?? creationDate(of: folder) ?? .now
        // session.json has the recording's rate (a still screen gives the file a much lower nominal rate).
        let fps = marker?.fps ?? (probe.fps.isFinite && probe.fps > 0 ? Int(probe.fps.rounded()) : 60)
        return RawRecording(
            id: id,
            sessionFolder: folder,
            screenURL: screenURL,
            eventsURL: metadata == nil ? nil : folder.appending(path: RawRecording.FileName.events),
            target: target,
            profile: isStudio ? .studio : .classic,
            format: .video,
            pixelSize: probe.pixelSize,
            pointSize: pointSize,
            scale: scale > 0 ? scale : 1,
            fps: fps,
            duration: probe.duration,
            // Without session.json the roles are unknown: the finalizer maps them by count.
            audioTracks: marker?.audioTracks ?? [],
            startDate: startDate
        )
    }

    private static func creationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// Latest modification date of the folder and anything inside it.
    static func newestModification(in folder: URL) -> Date? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        var newest = (try? folder.resourceValues(forKeys: Set(keys)))?.contentModificationDate
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return newest }
        for case let url as URL in enumerator {
            guard let date = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate else { continue }
            if newest.map({ date > $0 }) ?? true { newest = date }
        }
        return newest
    }

    private static func removeFolder(_ folder: URL) {
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            Log.recording.error("recovery: deleting \(folder.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// One session turned back into a recording.
nonisolated struct RecoveredRecording: Sendable {
    var sessionID: UUID
    /// `fileURL`: the History copy, or the fallback file when History is off.
    /// `historyID` set when History took it; `raw` is nil (folder deleted).
    var result: RecordingResult
    var historyItem: HistoryItem?
    /// Recorded in Studio Mode.
    var wasStudio: Bool
    /// The recovered `.hakostudio` (`nil`: classic video, also a Studio
    /// session whose package failed).
    var studioPackageURL: URL?
}

/// What a recovery pass did.
nonisolated struct RecoveryReport: Sendable {
    var recovered: [RecoveredRecording] = []
    /// Unusable folders removed (older than the age limit).
    var deleted: [URL] = []
    /// Unusable folders left for a later launch (too young to delete).
    var kept: [URL] = []
    /// Excluded (active) or still changing; not touched.
    var skipped: [URL] = []

    var recoveredCount: Int { recovered.count }

    /// "Recovered 1 recording" / "Recovered 3 recordings"; nil when nothing was recovered.
    var message: String? {
        switch recoveredCount {
        case 0: nil
        case 1: "Recovered 1 recording"
        default: "Recovered \(recoveredCount) recordings"
        }
    }
}
