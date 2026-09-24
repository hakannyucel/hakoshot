import AppKit
import CoreGraphics
import Foundation
import HakoKit
import os

/// Records cursor, clicks and keys for one recording session (plan §1.6,
/// §4.9, §4.10) and owns the four sources: `CursorTracker`,
/// `CursorShapeSampler`, `ClickMonitor`, `KeystrokeTap`.
///
/// Time: every event is stamped in host seconds by its source and mapped to
/// media time through the engine's `RecordingTimeline` (T0 + pauses). Events
/// before T0 or inside a pause are dropped.
/// - Clicks and keys are kept in host time and mapped once in `finish`, with
///   the final timeline from `events.json` (exact).
/// - Cursor samples are streamed to `cursor.bin` (`CursorTrackCodec`: header
///   with unknown count, records appended, count patched at `finish`). A
///   sample is written only once a timeline fetched **after** it is known
///   (refreshed every ~100 ms), so pause edges are exact. When the timeline
///   origin changes (engine restart) `cursor.bin` starts over. Repeated
///   identical samples (idle cursor) are skipped; the last one of an idle run
///   is written before the next change so interpolation stays flat.
///
/// Positions are points relative to the recording rect at the moment of the
/// event (`rect` is read per event, so window mode follows the window).
///
/// Privacy: keys are recorded only with `recordsKeystrokes`, and only the
/// presses that pass the badge filter (`KeystrokeFormatter`) are kept, even
/// in memory. `flagsChanged` (lone modifiers) is never kept.
@MainActor
final class EventRecorder {
    struct Configuration {
        /// `<session>/`; `cursor.bin` and `cursors/` go here.
        var sessionFolder: URL
        /// Recording fps; the cursor is sampled at 60…120 Hz from it.
        var fps: Int = 60
        var recordsKeystrokes = false
        var keystrokeFilter: KeystrokeDisplayFilter = .shortcutsOnly
        var tracksCursor = true
        var samplesCursorShapes = true
        var monitorsClicks = true
        var timelineRefreshInterval: Duration = .milliseconds(100)

        init(sessionFolder: URL, fps: Int = 60, recordsKeystrokes: Bool = false,
             keystrokeFilter: KeystrokeDisplayFilter = .shortcutsOnly) {
            self.sessionFolder = sessionFolder
            self.fps = fps
            self.recordsKeystrokes = recordsKeystrokes
            self.keystrokeFilter = keystrokeFilter
        }

        var cursorURL: URL { sessionFolder.appending(path: CursorTrackCodec.fileName) }
        var cursorsFolder: URL { sessionFolder.appending(path: "cursors", directoryHint: .isDirectory) }
    }

    /// What the keystroke source is doing (for the UI warning).
    enum KeystrokeState: String, Sendable, Equatable, Codable {
        /// "Show keystrokes" is off for this recording.
        case disabled
        case running
        /// Input Monitoring is not granted: keys are silently off.
        case permissionMissing
        /// The tap couldn't be created (usually needs a relaunch after granting).
        case tapFailed
    }

    typealias TimelineProvider = @Sendable () async -> RecordingTimeline?

    /// Live click (mouse downs only, not while paused): Quartz global point.
    var onClick: ((CGPoint, RecordingMouseButton) -> Void)?
    /// Live key press that passed the filter (not auto-repeats, not while
    /// paused): the badge text, e.g. "⇧⌘F".
    var onKey: ((String) -> Void)?

    /// The recorder of the running session (DEBUG injection, state dumps).
    private(set) static weak var active: EventRecorder?

    let configuration: Configuration
    private let timelineProvider: TimelineProvider
    private let rect: () -> CGRect
    private let hostClock: () -> Double
    private let keystrokeEnvironment: KeystrokeTap.Environment

    private var cursorTracker: CursorTracker?
    private(set) var shapeSampler: CursorShapeSampler?
    private var clickMonitor: ClickMonitor?
    private var keystrokeTap: KeystrokeTap?
    private var refreshTask: Task<Void, Never>?

    private(set) var isRunning = false
    private(set) var isFinished = false
    private(set) var keystrokeState: KeystrokeState = .disabled

    // Timeline cache.
    private(set) var timeline: RecordingTimeline?
    /// Samples strictly before this host time are classified by `timeline`.
    private var timelineValidBefore = -Double.infinity
    private var streamedOrigin: Double?

    // Host-time events.
    private(set) var clickEvents: [PendingClick] = []
    private(set) var keyEvents: [PendingKey] = []

    // Cursor streaming.
    private var cursorFile: FileHandle?
    private var pendingCursor: [PendingCursor] = []
    private var lastWritten: CursorSample?
    private var heldSample: CursorSample?
    private(set) var cursorSamplesWritten = 0
    static let maxPendingCursorSamples = 20_000

    struct PendingClick: Equatable {
        var hostTime: Double
        var globalPoint: CGPoint
        var localPoint: CGPoint
        var button: RecordingMouseButton
        var isDown: Bool
        var clickCount: Int
    }

    struct PendingKey: Equatable {
        var hostTime: Double
        var event: TappedKeyEvent
        var text: String
    }

    struct PendingCursor: Equatable {
        var hostTime: Double
        var localPoint: CGPoint
        var shapeIndex: UInt16
        var flags: CursorSampleFlags
    }

    /// - Parameters:
    ///   - timeline: the engine's live timeline (`{ await engine.timeline }`).
    ///   - rect: recording rect in Quartz global points, read per event.
    ///   - hostClock: host seconds now (tests pin it).
    init(
        configuration: Configuration,
        timeline: @escaping TimelineProvider,
        rect: @escaping () -> CGRect,
        hostClock: @escaping () -> Double = { HostTime.nowSeconds() },
        keystrokeEnvironment: KeystrokeTap.Environment = .live
    ) {
        self.configuration = configuration
        self.timelineProvider = timeline
        self.rect = rect
        self.hostClock = hostClock
        self.keystrokeEnvironment = keystrokeEnvironment
    }

    // MARK: Lifecycle

    /// Opens `cursor.bin` and starts the enabled sources and the timeline
    /// refresh. Never prompts for a permission. Call after `session.start`
    /// (the first frame is written; overlay windows are up).
    func start() {
        guard !isRunning, !isFinished else { return }
        isRunning = true
        Self.active = self
        openCursorFile()

        if configuration.samplesCursorShapes {
            let sampler = CursorShapeSampler(cursorsFolder: configuration.cursorsFolder)
            shapeSampler = sampler
            sampler.start()
        }
        if configuration.tracksCursor {
            let tracker = CursorTracker(rate: CursorTracker.rate(forFPS: configuration.fps), rect: rect) { [weak self] sample in
                self?.ingestCursor(sample)
            }
            cursorTracker = tracker
            tracker.start()
        }
        if configuration.monitorsClicks {
            let monitor = ClickMonitor { [weak self] event in self?.ingestClick(event) }
            clickMonitor = monitor
            monitor.start()
        }
        if configuration.recordsKeystrokes {
            let tap = makeKeystrokeTap()
            keystrokeState = Self.keystrokeState(for: tap.start())
        }

        let interval = configuration.timelineRefreshInterval
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    guard let self else { return }
                    await self.refreshTimeline()
                }
                try? await Task.sleep(for: interval)
            }
        }
        Log.recording.notice("event recorder started (keys: \(self.keystrokeState.rawValue, privacy: .public))")
    }

    /// Stops the sources (idempotent). Data stays until `finish` / `discard`.
    func stop() {
        cursorTracker?.stop()
        shapeSampler?.stop()
        clickMonitor?.stop()
        keystrokeTap?.stop()
        refreshTask?.cancel()
        refreshTask = nil
        cursorTracker = nil
        clickMonitor = nil
        isRunning = false
    }

    /// Restart: forgets everything recorded so far (the engine starts a new
    /// file with a new T0). Also done automatically when the origin changes.
    func reset() {
        clickEvents.removeAll()
        keyEvents.removeAll()
        pendingCursor.removeAll()
        restartCursorStream()
    }

    /// Stops, then merges clicks, keys and cursor shapes into the engine's
    /// `events.json` (read → merge → atomic write; pauses, geometry and the
    /// rest are kept) and completes `cursor.bin`. The file's timeline is the
    /// authority for media times. Returns the merged metadata.
    @discardableResult
    func finish(mergingInto metadataURL: URL) throws -> RecordingMetadata {
        stop()
        defer { finishCleanup() }
        var metadata = try RecordingMetadata(jsonData: Data(contentsOf: metadataURL))
        let final = metadata.timeline
        if let streamedOrigin, abs(streamedOrigin - final.origin) > 1e-6 {
            Log.recording.notice("event recorder: final origin differs from the streamed one; cursor track restarted")
            restartCursorStream()
        }
        timeline = final
        timelineValidBefore = .infinity
        flushCursor(using: final, upTo: .infinity)
        if let held = heldSample { writeCursor([held]); heldSample = nil }
        closeCursorFile()

        let merged = mappedEvents(using: final)
        metadata.clicks = merged.clicks
        if configuration.recordsKeystrokes { metadata.keys = merged.keys }
        metadata.cursorShapes = shapeSampler?.shapes ?? metadata.cursorShapes
        try metadata.jsonData().write(to: metadataURL, options: .atomic)
        Self.lastFinished = snapshot(using: final)
        Log.recording.notice("event recorder: \(metadata.clicks.count) clicks, \(metadata.keys.count) keys, \(self.cursorSamplesWritten) cursor samples, \(metadata.cursorShapes.count) shapes")
        return metadata
    }

    /// Stops and throws everything away (the session folder is deleted by the engine).
    func discard() {
        stop()
        closeCursorFile()
        finishCleanup()
    }

    private func finishCleanup() {
        isFinished = true
        if Self.active === self { Self.active = nil }
    }

    private func makeKeystrokeTap() -> KeystrokeTap {
        let tap = KeystrokeTap(environment: keystrokeEnvironment) { [weak self] event in self?.ingestKey(event) }
        keystrokeTap = tap
        return tap
    }

    static func keystrokeState(for status: KeystrokeTap.Status) -> KeystrokeState {
        switch status {
        case .running: .running
        case .permissionMissing: .permissionMissing
        case .tapFailed: .tapFailed
        case .off: .disabled
        }
    }

    /// The keystroke tap's secure-input skip flag (nil without a tap).
    var didSkipSecureInput: Bool { keystrokeTap?.didSkipSecureInput ?? false }

    // MARK: Timeline

    /// Fetches the engine timeline and writes every cursor sample taken
    /// before the fetch started.
    func refreshTimeline() async {
        let asked = hostClock()
        let fresh = await timelineProvider()
        applyTimeline(fresh, validBefore: asked)
    }

    func applyTimeline(_ fresh: RecordingTimeline?, validBefore: Double) {
        guard !isFinished else { return }
        guard let fresh else {
            // Between a restart and the new first frame: keep samples pending.
            timeline = nil
            return
        }
        if let streamedOrigin, abs(streamedOrigin - fresh.origin) > 1e-6 {
            Log.recording.notice("event recorder: timeline origin changed (restart); cursor track restarted")
            restartCursorStream()
        }
        streamedOrigin = fresh.origin
        timeline = fresh
        timelineValidBefore = validBefore
        flushCursor(using: fresh, upTo: validBefore)
    }

    /// Whether a live event at `host` should show (not paused, per the cached timeline).
    private func isLive(at host: Double) -> Bool {
        guard let timeline else { return true }
        if host < timeline.origin { return true }
        return timeline.mediaTime(host: host) != nil && !timeline.isPaused
    }

    // MARK: Ingestion (sources, DEBUG injection, tests)

    func ingestClick(_ event: MouseButtonEvent) {
        guard !isFinished else { return }
        let local = CursorTracker.localPoint(event.globalPoint, in: rect())
        clickEvents.append(PendingClick(
            hostTime: event.hostTime, globalPoint: event.globalPoint, localPoint: local,
            button: event.button, isDown: event.isDown, clickCount: event.clickCount
        ))
        if event.isDown, isLive(at: event.hostTime) { onClick?(event.globalPoint, event.button) }
    }

    func ingestKey(_ event: TappedKeyEvent) {
        guard !isFinished, configuration.recordsKeystrokes, event.kind == .keyDown else { return }
        guard let text = KeystrokeFormatter.displayText(
            keyCode: event.keyCode, modifierFlags: event.modifierFlags,
            characters: event.characters, filter: configuration.keystrokeFilter
        ) else { return }
        keyEvents.append(PendingKey(hostTime: event.hostTime, event: event, text: text))
        if !event.isRepeat, isLive(at: event.hostTime) { onKey?(text) }
    }

    /// Routes a key event through the tap's secure-input check (DEBUG
    /// injection uses this so it behaves like a real key).
    func injectKey(_ event: TappedKeyEvent) {
        if let keystrokeTap { keystrokeTap.ingest(event) } else { ingestKey(event) }
    }

    func ingestCursor(_ sample: CursorPositionSample) {
        guard !isFinished else { return }
        var flags = sample.flags
        if shapeSampler?.isHidden == true { flags.insert(.hidden) }
        pendingCursor.append(PendingCursor(
            hostTime: sample.hostTime, localPoint: sample.localPoint,
            shapeIndex: shapeSampler?.currentIndex ?? 0, flags: flags
        ))
        if pendingCursor.count > Self.maxPendingCursorSamples {
            pendingCursor.removeFirst(pendingCursor.count - Self.maxPendingCursorSamples)
        }
        if let timeline, sample.hostTime < timelineValidBefore {
            flushCursor(using: timeline, upTo: timelineValidBefore)
        }
    }

    // MARK: Mapping

    struct MappedEvents: Equatable {
        var clicks: [RecordingClickEvent]
        var keys: [RecordingKeyEvent]
    }

    func mappedEvents(using timeline: RecordingTimeline) -> MappedEvents {
        let clicks = clickEvents.compactMap { click -> RecordingClickEvent? in
            guard let time = timeline.mediaTime(host: click.hostTime) else { return nil }
            return RecordingClickEvent(
                time: time, x: Double(click.localPoint.x), y: Double(click.localPoint.y),
                button: click.button, isDown: click.isDown, clickCount: click.clickCount
            )
        }
        let keys = keyEvents.compactMap { key -> RecordingKeyEvent? in
            guard let time = timeline.mediaTime(host: key.hostTime) else { return nil }
            return RecordingKeyEvent(
                time: time, kind: .keyDown, keyCode: key.event.keyCode,
                modifierFlags: key.event.modifierFlags, characters: key.event.characters, isRepeat: key.event.isRepeat
            )
        }
        return MappedEvents(
            clicks: clicks.sorted { $0.time < $1.time },
            keys: keys.sorted { $0.time < $1.time }
        )
    }

    // MARK: cursor.bin

    private func openCursorFile() {
        let url = configuration.cursorURL
        do {
            try FileManager.default.createDirectory(at: configuration.sessionFolder, withIntermediateDirectories: true)
            try CursorTrackCodec.header(recordCount: nil).write(to: url, options: .atomic)
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            cursorFile = handle
        } catch {
            Log.recording.error("cursor.bin: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func restartCursorStream() {
        lastWritten = nil
        heldSample = nil
        cursorSamplesWritten = 0
        streamedOrigin = nil
        guard let cursorFile else { return }
        do {
            try cursorFile.truncate(atOffset: UInt64(CursorTrackCodec.headerSize))
            try cursorFile.seekToEnd()
        } catch {
            Log.recording.error("cursor.bin truncate: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Maps and writes pending samples taken before `limit`.
    private func flushCursor(using timeline: RecordingTimeline, upTo limit: Double) {
        guard !pendingCursor.isEmpty else { return }
        let ready = pendingCursor.prefix { $0.hostTime < limit }
        guard !ready.isEmpty else { return }
        pendingCursor.removeFirst(ready.count)
        var batch: [CursorSample] = []
        for pending in ready {
            guard let time = timeline.mediaTime(host: pending.hostTime) else { continue }
            let sample = CursorSample(
                time: time, x: Float(pending.localPoint.x), y: Float(pending.localPoint.y),
                shapeIndex: pending.shapeIndex, flags: pending.flags
            )
            if let last = lastWritten, Self.isSamePlace(sample, last) {
                heldSample = sample
                continue
            }
            if let held = heldSample {
                batch.append(held)
                heldSample = nil
            }
            batch.append(sample)
            lastWritten = sample
        }
        writeCursor(batch)
    }

    nonisolated static func isSamePlace(_ a: CursorSample, _ b: CursorSample) -> Bool {
        a.x == b.x && a.y == b.y && a.shapeIndex == b.shapeIndex && a.flags == b.flags
    }

    private func writeCursor(_ samples: [CursorSample]) {
        guard !samples.isEmpty else { return }
        var data = Data(capacity: samples.count * CursorTrackCodec.recordSize)
        for sample in samples { data.append(CursorTrackCodec.record(sample)) }
        do {
            try cursorFile?.write(contentsOf: data)
            cursorSamplesWritten += samples.count
        } catch {
            Log.recording.error("cursor.bin write: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeCursorFile() {
        guard let cursorFile else { return }
        do {
            try cursorFile.seek(toOffset: UInt64(CursorTrackCodec.countOffset))
            try cursorFile.write(contentsOf: CursorTrackCodec.countField(cursorSamplesWritten))
            try cursorFile.synchronize()
            try cursorFile.close()
        } catch {
            Log.recording.error("cursor.bin close: \(error.localizedDescription, privacy: .public)")
        }
        self.cursorFile = nil
    }

    // MARK: State dump

    /// JSON-friendly view of what's recorded (DEBUG `debug-recording-events`).
    struct Snapshot: Codable, Equatable {
        struct Click: Codable, Equatable {
            var time: Double
            var x: Double
            var y: Double
            var button: String
            var isDown: Bool
        }

        struct Key: Codable, Equatable {
            var time: Double
            var text: String
            var keyCode: UInt16
            var isRepeat: Bool
        }

        var sessionFolder: String
        var isRunning: Bool
        var keystrokeState: KeystrokeState
        var didSkipSecureInput: Bool
        var timelineOrigin: Double?
        var pauses: [[Double]]
        var clicks: [Click]
        var keys: [Key]
        var cursorSamplesWritten: Int
        var cursorSamplesPending: Int
        var cursorShapes: Int
    }

    /// Snapshot of the last finished recorder (after stop, for smoke tests).
    private(set) static var lastFinished: Snapshot?

    /// Current state, events mapped with the cached timeline (or `using`).
    func snapshot(using timeline: RecordingTimeline? = nil) -> Snapshot {
        let timeline = timeline ?? self.timeline
        let mapped = timeline.map(mappedEvents(using:)) ?? MappedEvents(clicks: [], keys: [])
        return Snapshot(
            sessionFolder: configuration.sessionFolder.path,
            isRunning: isRunning,
            keystrokeState: keystrokeState,
            didSkipSecureInput: didSkipSecureInput,
            timelineOrigin: timeline?.origin,
            pauses: timeline?.pauses.map { [$0.lowerBound, $0.upperBound] } ?? [],
            clicks: mapped.clicks.map { Snapshot.Click(time: $0.time, x: $0.x, y: $0.y, button: $0.button.rawValue, isDown: $0.isDown) },
            // Stored keys already passed the filter, so `.allKeys` gives the same text.
            keys: mapped.keys.map { key in
                Snapshot.Key(time: key.time, text: KeystrokeFormatter.displayText(for: key, filter: .allKeys) ?? "",
                             keyCode: key.keyCode, isRepeat: key.isRepeat)
            },
            cursorSamplesWritten: cursorSamplesWritten,
            cursorSamplesPending: pendingCursor.count,
            cursorShapes: shapeSampler?.shapes.count ?? 0
        )
    }
}
