import CoreGraphics
import Foundation
import HakoKit
import os

/// Capture history on disk (plan §1.6, §4.12).
///
/// Layout under `rootURL` (default `~/Library/Application Support/HakoShot/History/`):
/// ```
/// history.json                    index (HistoryIndex JSON, written atomically)
/// 2026-09/<uuid>.png              original, full resolution, 72×scale DPI
/// 2026-09/<uuid>-thumb.jpg        thumbnail, longest edge ≤ 480 px
/// 2026-09/<uuid>.hakoshot         editable project (M5, optional)
/// history.corrupt.json            last unreadable index, kept for inspection
/// ```
/// The index is loaded lazily on first use and reconciled with the folder
/// (entries whose original vanished are dropped, originals missing from the
/// index are re-adopted), so a lost or corrupt `history.json` loses metadata
/// only, not captures. Expired entries are purged on launch and every 24 h
/// (`startMaintenance()`).
actor HistoryStore {
    static let shared = HistoryStore(
        rootURL: HistoryStore.defaultRootURL,
        configuration: { @MainActor in AppSettings.shared.historyConfiguration }
    )

    nonisolated static var defaultRootURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "HakoShot/History", directoryHint: .isDirectory)
    }

    nonisolated static let maintenanceInterval: Duration = .seconds(24 * 60 * 60)
    nonisolated static let corruptIndexFileName = "history.corrupt.json"

    nonisolated let rootURL: URL
    private let configuration: @Sendable () async -> HistoryConfiguration
    private let now: @Sendable () -> Date
    private let calendar: Calendar

    private var index = HistoryIndex()
    private var isLoaded = false
    private var maintenanceTask: Task<Void, Never>?

    /// - Parameters:
    ///   - rootURL: history folder; tests pass a temporary directory.
    ///   - configuration: current settings (read on every add / purge).
    ///   - now: injectable clock for retention.
    init(
        rootURL: URL,
        configuration: @escaping @Sendable () async -> HistoryConfiguration = { .default },
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: Calendar = .current
    ) {
        self.rootURL = rootURL
        self.configuration = configuration
        self.now = now
        self.calendar = calendar
    }

    nonisolated var indexURL: URL { rootURL.appending(path: HistoryLayout.indexFileName) }

    /// Absolute URL of a root-relative history file name.
    nonisolated func fileURL(_ relativeName: String) -> URL {
        rootURL.appending(path: relativeName)
    }

    /// The stored full-resolution PNG (for drag, Show in Finder, Quick Look).
    nonisolated func imageURL(for item: HistoryItem) -> URL { fileURL(item.imageFileName) }

    // MARK: - Adding

    /// Stores `result` as a new entry. Returns `nil` when history is off
    /// (disabled or retention `.never`) or writing failed. Pass `id` to know the
    /// entry's id before the (async) write finishes, e.g. to tag a Quick Access card.
    @discardableResult
    func add(_ result: CaptureResult, savedURL: URL?, id: UUID = UUID()) async -> HistoryItem? {
        let config = await configuration()
        guard config.records else { return nil }
        ensureLoaded()

        let item = HistoryItem(
            id: id,
            date: result.date,
            kind: result.mode.historyKind,
            pixelWidth: result.image.width,
            pixelHeight: result.image.height,
            scale: Double(result.scale),
            imageFileName: HistoryLayout.imageFileName(id: id, date: result.date, calendar: calendar),
            thumbnailFileName: HistoryLayout.thumbnailFileName(id: id, date: result.date, calendar: calendar),
            savedFileURL: savedURL
        )

        do {
            let imageURL = fileURL(item.imageFileName)
            try FileManager.default.createDirectory(
                at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let png = try ImageEncoder.encode(
                result.image, format: .png,
                options: ImageEncodeOptions(compressionQuality: 1, dpi: 72 * result.scale)
            )
            try png.write(to: imageURL, options: .atomic)
        } catch {
            Log.history.error("add: writing original failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if let thumb = HistoryThumbnail.jpegThumbnail(of: result.image) {
            do {
                try thumb.write(to: fileURL(item.thumbnailFileName), options: .atomic)
            } catch {
                // Not fatal: thumbnail(for:) falls back to downsampling the original.
                Log.history.error("add: writing thumbnail failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        index.add(item)
        persist()
        Log.history.info("added \(id.uuidString, privacy: .public) \(item.pixelWidth)x\(item.pixelHeight)")
        return item
    }

    // MARK: - Updating

    /// Marks the entry's Quick Access card as closed ("Restore Recently Closed" candidate).
    func markClosed(id: UUID) {
        ensureLoaded()
        guard index.markClosed(id: id, at: now()) != nil else { return }
        persist()
    }

    /// Clears the closed flag (call after restoring the entry to Quick Access).
    func markReopened(id: UUID) {
        ensureLoaded()
        guard index.markReopened(id: id) != nil else { return }
        persist()
    }

    /// Records where the capture was saved by the user.
    func setSavedURL(_ url: URL?, for id: UUID) {
        ensureLoaded()
        guard index.update(id: id, { $0.savedFileURL = url }) != nil else { return }
        persist()
    }

    /// Links an editable project (M5). `name` is root-relative, see
    /// `HistoryLayout.projectFileName(id:date:)`; the caller writes the bundle
    /// at `fileURL(name)`.
    func setProjectFileName(_ name: String?, for id: UUID) {
        ensureLoaded()
        guard index.update(id: id, { $0.projectFileName = name }) != nil else { return }
        persist()
    }

    // MARK: - Reading

    func recent(limit: Int? = nil, filter: HistoryFilter = .all) -> [HistoryItem] {
        ensureLoaded()
        return index.recent(limit: limit, filter: filter)
    }

    func item(id: UUID) -> HistoryItem? {
        ensureLoaded()
        return index.item(id: id)
    }

    /// The most recently closed entry, if any.
    func lastClosed() -> HistoryItem? {
        ensureLoaded()
        return index.lastClosed()
    }

    /// Full-resolution original.
    func image(for item: HistoryItem) -> CGImage? {
        guard let data = try? Data(contentsOf: imageURL(for: item)) else { return nil }
        return ImageEncoder.decode(data)
    }

    func image(for id: UUID) -> CGImage? {
        guard let item = item(id: id) else { return nil }
        return image(for: item)
    }

    /// Stored thumbnail, or a downsampled original when the thumbnail is missing.
    func thumbnail(for item: HistoryItem) -> CGImage? {
        let thumbURL = fileURL(item.thumbnailFileName)
        if let data = try? Data(contentsOf: thumbURL), let image = ImageEncoder.decode(data) {
            return image
        }
        return HistoryThumbnail.downsample(contentsOf: imageURL(for: item), maxPixelSize: HistoryLayout.thumbnailMaxPixelSize)
    }

    /// Original downsampled to `maxPixelSize` (large selected card in the overlay).
    func preview(for item: HistoryItem, maxPixelSize: Int) -> CGImage? {
        HistoryThumbnail.downsample(contentsOf: imageURL(for: item), maxPixelSize: maxPixelSize)
    }

    // MARK: - Removing

    @discardableResult
    func remove(id: UUID) -> HistoryItem? {
        ensureLoaded()
        guard let removed = index.remove(id: id) else { return nil }
        deleteFiles(of: [removed])
        persist()
        return removed
    }

    /// Deletes every entry and its files.
    func clearAll() {
        ensureLoaded()
        let removed = index.removeAll()
        deleteFiles(of: removed)
        for folder in monthFolders() {
            try? FileManager.default.removeItem(at: folder)
        }
        persist()
        Log.history.notice("cleared \(removed.count) entries")
    }

    /// Deletes entries past the configured retention. Returns how many were removed.
    @discardableResult
    func purgeExpired() async -> Int {
        let config = await configuration()
        ensureLoaded()
        let policy = RetentionPolicy(retention: config.retention, calendar: calendar)
        let expired = policy.itemsToPurge(in: index.items, now: now())
        guard !expired.isEmpty else { return 0 }
        index.remove(ids: Set(expired.map(\.id)))
        deleteFiles(of: expired)
        persist()
        Log.history.notice("purged \(expired.count) expired entries (\(config.retention.rawValue, privacy: .public))")
        return expired.count
    }

    /// Purges now and then every 24 h. Idempotent; call once at launch.
    func startMaintenance() {
        guard maintenanceTask == nil else { return }
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.purgeExpired()
                try? await Task.sleep(for: Self.maintenanceInterval)
            }
        }
    }

    func stopMaintenance() {
        maintenanceTask?.cancel()
        maintenanceTask = nil
    }

    // MARK: - Loading / persistence

    private func ensureLoaded() {
        guard !isLoaded else { return }
        isLoaded = true
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            Log.history.error("cannot create history folder: \(error.localizedDescription, privacy: .public)")
        }

        var needsWrite = false
        if let data = try? Data(contentsOf: indexURL) {
            let result = HistoryIndex.load(from: data)
            index = result.index
            switch result.status {
            case .ok:
                break
            case .partiallyRecovered(let dropped):
                Log.history.error("index: dropped \(dropped) unreadable entries")
                needsWrite = true
            case .corrupt:
                Log.history.error("index unreadable; moved aside and rebuilding from files")
                let aside = fileURL(Self.corruptIndexFileName)
                try? fm.removeItem(at: aside)
                try? fm.moveItem(at: indexURL, to: aside)
                needsWrite = true
            }
        }

        if reconcileWithDisk() { needsWrite = true }
        if needsWrite { persist() }
    }

    /// Drops entries whose original is gone, re-adopts originals missing from
    /// the index. Returns whether the index changed.
    private func reconcileWithDisk() -> Bool {
        let fm = FileManager.default
        var changed = false

        var missing: [HistoryItem] = []
        for item in index.items where !fm.fileExists(atPath: imageURL(for: item).path) {
            missing.append(item)
        }
        if !missing.isEmpty {
            index.remove(ids: Set(missing.map(\.id)))
            deleteFiles(of: missing)
            changed = true
        }

        for folder in monthFolders() {
            let files = (try? fm.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
            )) ?? []
            for file in files {
                let relative = "\(folder.lastPathComponent)/\(file.lastPathComponent)"
                guard let id = HistoryLayout.id(fromImageFileName: relative), index.item(id: id) == nil else { continue }
                index.add(adoptedItem(id: id, relativeImageName: relative, url: file))
                changed = true
            }
        }
        if changed { Log.history.notice("reconciled index with disk: \(self.index.count) entries") }
        return changed
    }

    private func adoptedItem(id: UUID, relativeImageName: String, url: URL) -> HistoryItem {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let date = values?.creationDate ?? values?.contentModificationDate ?? now()
        let info = HistoryThumbnail.pixelSize(of: url)
        let scale = max(1, ((info?.dpi ?? 72) / 72).rounded())
        let projectName = (relativeImageName as NSString).deletingPathExtension + "." + HistoryLayout.projectExtension
        return HistoryItem(
            id: id,
            date: date,
            kind: .unknown,
            pixelWidth: info?.width ?? 0,
            pixelHeight: info?.height ?? 0,
            scale: scale,
            imageFileName: relativeImageName,
            thumbnailFileName: HistoryLayout.thumbnailFileName(forImageFileName: relativeImageName),
            projectFileName: FileManager.default.fileExists(atPath: fileURL(projectName).path) ? projectName : nil
        )
    }

    /// `yyyy-MM` folders directly under the root.
    private func monthFolders() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey]
        )) ?? []
        return contents.filter { url in
            let name = url.lastPathComponent
            return name.count == 7 && name.wholeMatch(of: /\d{4}-\d{2}/) != nil
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
    }

    private func deleteFiles(of items: [HistoryItem]) {
        let fm = FileManager.default
        var folders = Set<URL>()
        for item in items {
            for name in item.ownedFileNames {
                let url = fileURL(name)
                folders.insert(url.deletingLastPathComponent())
                try? fm.removeItem(at: url)
            }
        }
        // Remove month folders left empty.
        for folder in folders where folder != rootURL {
            if let contents = try? fm.contentsOfDirectory(atPath: folder.path),
               contents.allSatisfy({ $0 == ".DS_Store" }) {
                try? fm.removeItem(at: folder)
            }
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try index.encoded().write(to: indexURL, options: .atomic)
        } catch {
            Log.history.error("writing index failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - CaptureMode ↔ HistoryCaptureKind

extension CaptureMode {
    nonisolated var historyKind: HistoryCaptureKind {
        switch self {
        case .area: .area
        case .window: .window
        case .fullscreen: .fullscreen
        case .previousArea: .previousArea
        case .scrolling: .scrolling
        case .selfTimer: .selfTimer
        case .allInOne: .allInOne
        case .text: .text
        }
    }
}

extension HistoryCaptureKind {
    /// Best-effort mapping back to a capture mode (restore → Quick Access).
    nonisolated var captureMode: CaptureMode {
        switch self {
        case .area, .unknown: .area
        case .window: .window
        case .fullscreen: .fullscreen(.preferred)
        case .previousArea: .previousArea
        case .scrolling: .scrolling
        case .selfTimer: .selfTimer
        case .allInOne: .allInOne
        case .text: .text
        }
    }
}

extension HistoryItem {
    /// Rebuilds a `CaptureResult` for restoring this entry (e.g. into Quick Access).
    nonisolated func captureResult(image: CGImage) -> CaptureResult {
        let scale = CGFloat(max(scale, 1))
        return CaptureResult(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
            scale: scale,
            mode: kind.captureMode,
            date: date
        )
    }
}
