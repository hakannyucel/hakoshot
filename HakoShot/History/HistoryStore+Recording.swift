import CoreGraphics
import Foundation
import HakoKit
import os

/// Video / GIF history entries (kayit-teknik-plan.md §4.15, R0.4).
///
/// Mirrors `HistoryStore.add(_:savedURL:id:)` for screenshots: the finished
/// recording's `thumbnail` becomes the entry's "image" (a full-resolution
/// preview PNG plus a small JPEG thumbnail, same layout as a screenshot), and
/// the delivered mp4/gif is copied alongside as `mediaFileName`. Works
/// unchanged for GIFs — `RecordingResult.format` picks the extension and the
/// `HistoryCaptureKind` (`.recording` for video, `.gif` for GIF).
///
/// This file only calls `HistoryStore`'s existing `internal` API plus two
/// small hooks added for it (`currentConfiguration()`, `insert(_:)`,
/// `calendar` widened from `private` to internal) — see `HistoryStore.swift`
/// "MARK: - Adding" for those; everything else here is new.
extension HistoryStore {
    /// Stores a finished recording (video or GIF) as a new history entry.
    /// Copies `result.fileURL` into the history folder, writes a preview PNG
    /// and thumbnail JPEG from `result.thumbnail`, and indexes the entry.
    /// Returns `nil` when history is off (disabled or retention `.never`) or
    /// writing failed. Pass `id` to know the entry's id before this returns.
    @discardableResult
    func addRecording(_ result: RecordingResult, id: UUID = UUID()) async -> HistoryItem? {
        let config = await currentConfiguration()
        guard config.records else { return nil }

        let kind: HistoryCaptureKind = result.format == .gif ? .gif : .recording
        let mediaFormat: HistoryMediaFormat = result.format == .gif ? .gif : .video
        let mediaName = HistoryLayout.mediaFileName(id: id, date: result.date, format: mediaFormat, calendar: calendar)
        let imageName = HistoryLayout.imageFileName(id: id, date: result.date, calendar: calendar)
        let thumbName = HistoryLayout.thumbnailFileName(id: id, date: result.date, calendar: calendar)
        let mediaDestination = fileURL(mediaName)

        do {
            try FileManager.default.createDirectory(
                at: mediaDestination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: mediaDestination.path) {
                try FileManager.default.removeItem(at: mediaDestination)
            }
            try FileManager.default.copyItem(at: result.fileURL, to: mediaDestination)
        } catch {
            Log.history.error("addRecording: copying media failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        do {
            let png = try ImageEncoder.encode(
                result.thumbnail, format: .png, options: ImageEncodeOptions(compressionQuality: 1, dpi: 72)
            )
            try png.write(to: fileURL(imageName), options: .atomic)
        } catch {
            Log.history.error("addRecording: writing preview failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.removeItem(at: mediaDestination)
            return nil
        }

        if let thumb = HistoryThumbnail.jpegThumbnail(of: result.thumbnail) {
            do {
                try thumb.write(to: fileURL(thumbName), options: .atomic)
            } catch {
                // Not fatal: thumbnail(for:) falls back to downsampling the preview PNG.
                Log.history.error("addRecording: writing thumbnail failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let eventsName = copyEvents(of: result, id: id)

        let item = HistoryItem(
            id: id,
            date: result.date,
            kind: kind,
            pixelWidth: max(0, Int(result.pixelSize.width.rounded())),
            pixelHeight: max(0, Int(result.pixelSize.height.rounded())),
            scale: Double(result.raw?.scale ?? 1),
            imageFileName: imageName,
            thumbnailFileName: thumbName,
            mediaFileName: mediaName,
            durationSeconds: result.duration,
            mediaFormat: mediaFormat,
            eventsFileName: eventsName
        )
        let inserted = insert(item)
        Log.history.info("addRecording \(id.uuidString, privacy: .public) \(inserted.pixelWidth)x\(inserted.pixelHeight)")

        await enforceVideoByteCap()
        return inserted
    }

    /// Keeps a video's `events.json` (cursor, clicks, keys) next to it so
    /// "Open in Studio" can plan auto zooms later (R5.I). Videos only; `nil`
    /// when there is none or copying failed (not fatal).
    private func copyEvents(of result: RecordingResult, id: UUID) -> String? {
        guard result.format == .video, let source = result.raw?.eventsURL,
              FileManager.default.fileExists(atPath: source.path)
        else { return nil }
        let name = HistoryLayout.eventsFileName(id: id, date: result.date, calendar: calendar)
        let destination = fileURL(name)
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: source, to: destination)
            return name
        } catch {
            Log.history.error("addRecording: copying events failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// The stored copy of the entry's video/GIF file (playback, editor,
    /// Studio, drag). `nil` for screenshots.
    nonisolated func mediaURL(for item: HistoryItem) -> URL? {
        item.mediaFileName.map(fileURL)
    }

    // MARK: Studio (R6.3, R6.I)

    /// The entry's `.hakostudio` package (Studio Mode recording, or an
    /// "Open in Studio" of its video), if it has one.
    nonisolated func studioPackageURL(for item: HistoryItem) -> URL? {
        item.studioPackageName.map(fileURL)
    }

    /// Where a new Studio recording's package goes for entry `id`
    /// (`<yyyy-MM>/<uuid>.hakostudio`); `nil` when History is off.
    func newStudioPackageURL(id: UUID, date: Date) async -> URL? {
        guard await currentConfiguration().records else { return nil }
        return fileURL(HistoryLayout.studioPackageName(id: id, date: date, calendar: calendar))
    }

    /// Indexes a Studio Mode recording whose package is already at
    /// `newStudioPackageURL(id:date:)` (kind `.studio`, no mp4): `preview`
    /// becomes the entry's image and thumbnail. `nil` when History is off or
    /// writing failed (the package stays).
    @discardableResult
    func addStudioProject(
        id: UUID, date: Date, preview: CGImage, pixelSize: CGSize, scale: Double, duration: Double
    ) async -> HistoryItem? {
        guard await currentConfiguration().records else { return nil }
        let packageName = HistoryLayout.studioPackageName(id: id, date: date, calendar: calendar)
        guard FileManager.default.fileExists(atPath: fileURL(packageName).path) else {
            Log.history.error("addStudioProject: no package at \(packageName, privacy: .public)")
            return nil
        }
        let imageName = HistoryLayout.imageFileName(id: id, date: date, calendar: calendar)
        let thumbName = HistoryLayout.thumbnailFileName(id: id, date: date, calendar: calendar)
        do {
            let png = try ImageEncoder.encode(preview, format: .png, options: ImageEncodeOptions(compressionQuality: 1, dpi: 72))
            try png.write(to: fileURL(imageName), options: .atomic)
        } catch {
            Log.history.error("addStudioProject: writing preview failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        if let thumb = HistoryThumbnail.jpegThumbnail(of: preview) {
            try? thumb.write(to: fileURL(thumbName), options: .atomic)
        }
        let item = HistoryItem(
            id: id,
            date: date,
            kind: .studio,
            pixelWidth: max(0, Int(pixelSize.width.rounded())),
            pixelHeight: max(0, Int(pixelSize.height.rounded())),
            scale: scale,
            imageFileName: imageName,
            thumbnailFileName: thumbName,
            durationSeconds: duration,
            mediaFormat: .video,
            studioPackageName: packageName
        )
        let inserted = insert(item)
        Log.history.info("addStudioProject \(id.uuidString, privacy: .public) \(inserted.pixelWidth)x\(inserted.pixelHeight)")
        await enforceVideoByteCap()
        return inserted
    }

    /// Bytes of a file or of a package directory (recursively).
    nonisolated static func byteSize(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
        }
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Deletes the oldest video/GIF/Studio entries until the combined size of
    /// their media files is back under `policy.byteCap` (plan §4.15/§5: kept
    /// as full copies, 10 GB cap, oldest evicted first). Safe to call anytime;
    /// a no-op when nothing is over the cap. Called automatically after
    /// `addRecording`.
    func enforceVideoByteCap(policy: VideoRetentionPolicy = VideoRetentionPolicy()) async {
        let candidates = recent(filter: .recordings)
        guard !candidates.isEmpty else { return }

        var sizes: [UUID: Int64] = [:]
        for entry in candidates {
            // Studio Mode entries: the package (raw Ultra media); others: the mp4 / GIF.
            if entry.kind == .studio, let package = entry.studioPackageName {
                sizes[entry.id] = Self.byteSize(of: fileURL(package))
            } else if let name = entry.mediaFileName {
                sizes[entry.id] = Self.byteSize(of: fileURL(name))
            }
        }

        let toEvict = policy.itemsToEvict(in: candidates, sizes: sizes)
        guard !toEvict.isEmpty else { return }
        for entry in toEvict {
            remove(id: entry.id)
        }
        Log.history.notice("video byte cap: evicted \(toEvict.count) entries")
    }
}
