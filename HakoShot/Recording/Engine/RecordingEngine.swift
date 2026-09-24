import CoreGraphics
import CoreMedia
import Foundation
import HakoKit
import os

/// Where and how big a recording is, resolved from a `RecordingTarget`.
nonisolated struct ResolvedRecordingTarget: Sendable, Equatable {
    var displayID: CGDirectDisplayID
    /// Recorded rect in Quartz global points.
    var globalRect: GlobalRect
    /// Stream `sourceRect` in display-local points; `nil` = the whole display.
    var sourceRect: CGRect?
    /// Display backing scale.
    var scale: CGFloat

    var pointSize: CGSize { globalRect.size }
}

/// Runs one screen recording at a time: frame source → `RecordingWriter` →
/// session folder (plan §2.2, §4.5).
///
/// Frames go from the source's queue straight into the writer (no actor hop
/// per frame); the actor only owns the session lifecycle.
///
/// Session folder: `<sessionsRoot>/<uuid>/` with `screen.mov` (fragmented
/// QuickTime) and `events.json` (HakoKit `RecordingMetadata`: host time
/// origin, geometry, dropped frames; events come with R1/R4).
///
/// Pause / resume keep the source running and let the writer drop and
/// re-stamp samples (`SampleRetimer`, plan §4.6). Restart swaps in a fresh
/// writer for the same file behind `WriterSlot`, so the source handlers never
/// change.
actor RecordingEngine {
    /// Session folders live here by default (plan §4.5).
    nonisolated static var defaultSessionsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "HakoShot/Recordings", directoryHint: .isDirectory)
    }

    /// Plan §4.5: warn under 2 GB free (the coordinator shows it); refuse to
    /// start under `minimumFreeBytes`.
    nonisolated static let lowDiskSpaceWarningBytes: Int64 = 2 * 1024 * 1024 * 1024
    nonisolated static let minimumFreeBytes: Int64 = 256 * 1024 * 1024

    /// The app's engine (coordinator, debug URL).
    static let shared = RecordingEngine()

    /// State of the running session.
    private struct Session {
        var handle: RecordingHandle
        var request: RecordingRequest
        var resolved: ResolvedRecordingTarget
        var plan: RecordingOutputPlan
        var fps: Int
        var source: any RecordingFrameSource
        /// Current writer + first-frame signal (replaced by `restart()`).
        var slot: WriterSlot
        /// Audio sources recorded (track order) and their live levels.
        var audioTracks: [AudioTrackKind]
        var meter: AudioLevelMeter

        var writer: RecordingWriter { slot.writer }
    }

    let sessionsRoot: URL
    private var session: Session?
    /// Set across the awaits of `start` so a second start is refused.
    private var isStarting = false
    private var failure: RecordingError?
    private var onUnexpectedStop: (@Sendable (RecordingError) -> Void)?

    init(sessionsRoot: URL = RecordingEngine.defaultSessionsRoot) {
        self.sessionsRoot = sessionsRoot
    }

    var isRecording: Bool { session != nil }

    /// Called (from any queue) when the source or writer fails while
    /// recording. The session stays open; the coordinator should `stop()`
    /// (keeps what was written) or `discard()`.
    func setUnexpectedStopHandler(_ handler: (@Sendable (RecordingError) -> Void)?) {
        onUnexpectedStop = handler
    }

    // MARK: Start

    /// Resolves the target, creates the session folder and writer, and starts
    /// the frame source. `overlayWindowIDs`: our windows that must appear in
    /// the video (must already be on screen).
    func start(_ request: RecordingRequest, overlayWindowIDs: [CGWindowID] = []) async throws -> RecordingHandle {
        guard session == nil, !isStarting else { throw RecordingError.alreadyRecording }
        isStarting = true
        defer { isStarting = false }
        failure = nil

        let isSynthetic = Self.usesSyntheticSource(request)
        let layout = await DisplayLayoutProvider.currentLayout()
        let resolved: ResolvedRecordingTarget
        do {
            resolved = try Self.resolve(request.target, layout: layout, windowBounds: Self.windowBounds(of:))
        } catch let error as RecordingError where isSynthetic {
            // The synthetic source needs no display (headless test hosts).
            guard let fallback = Self.syntheticFallback(for: request.target) else { throw error }
            resolved = fallback
        }

        let fps = Self.effectiveFPS(request, displayRefreshRate: Self.refreshRate(of: resolved.displayID))
        let plan = Self.outputPlan(request, resolved: resolved)
        let quality = Self.effectiveQuality(request)
        let audioTracks = Self.audioTracks(request)

        let id = UUID()
        let folder = sessionsRoot.appending(path: id.uuidString, directoryHint: .isDirectory)
        try Self.checkDiskSpace(at: sessionsRoot)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw RecordingError.writerFailed("session folder: \(error.localizedDescription)")
        }
        let screenURL = folder.appending(path: RawRecording.FileName.screen)
        // Crash recovery needs the profile and geometry before events.json exists (plan §4.22).
        RecordingSessionMarker(request: request, resolved: resolved, plan: plan, fps: fps, audioTracks: audioTracks)
            .write(toSessionFolder: folder)

        let writer: RecordingWriter
        do {
            writer = try RecordingWriter(configuration: RecordingWriterConfiguration(
                outputURL: screenURL, plan: plan, quality: quality, fps: fps, audioTracks: audioTracks
            ))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }

        let source = Self.makeSource(request)
        let slot = WriterSlot(writer: writer)
        let meter = AudioLevelMeter()
        let sourceConfiguration = RecordingSourceConfiguration(
            target: request.target,
            displayID: resolved.displayID,
            sourceRect: resolved.sourceRect,
            pixelSize: plan.pixelSize,
            fps: fps,
            showsCursor: request.profile == .studio ? false : request.options.showsCursor,
            capturesSystemAudio: audioTracks.contains(.system),
            microphone: audioTracks.contains(.microphone) ? request.options.microphone : nil,
            exceptedWindowIDs: overlayWindowIDs,
            excludesNotifications: request.options.doNotDisturb
        )
        let handlers = RecordingFrameSourceHandlers(
            onVideo: { [slot] sampleBuffer in
                let (writer, firstFrame) = slot.current
                if writer.appendVideo(sampleBuffer) { firstFrame.signal() }
            },
            onAudio: { [slot, meter] sampleBuffer, kind in
                meter.process(sampleBuffer, kind: kind)
                slot.current.writer.appendAudio(sampleBuffer, kind: kind)
            },
            onStop: { [weak self] error in
                let reason = RecordingError.sourceFailed(error?.localizedDescription ?? "source stopped")
                Task { await self?.reportFailure(reason) }
            }
        )
        installFailureHandler(on: writer)

        let handle = RecordingHandle(
            id: id,
            sessionFolder: folder,
            target: request.target,
            profile: request.profile,
            sourceRect: resolved.globalRect,
            displayID: resolved.displayID,
            pixelSize: plan.pixelSize,
            pointSize: resolved.pointSize,
            scale: resolved.scale,
            startDate: .now
        )
        session = Session(
            handle: handle, request: request, resolved: resolved, plan: plan, fps: fps,
            source: source, slot: slot, audioTracks: audioTracks, meter: meter
        )
        do {
            try await source.start(sourceConfiguration, handlers: handlers)
        } catch {
            session = nil
            await source.stop()
            writer.cancel()
            try? FileManager.default.removeItem(at: folder)
            Log.recording.error("start failed: \(String(describing: error), privacy: .public)")
            throw (error as? RecordingError) ?? RecordingError.sourceFailed(error.localizedDescription)
        }
        // `discard()` ran while the source was starting: it already removed
        // the folder and cancelled the writer, but the source is ours to stop.
        guard session?.handle.id == id else {
            await source.stop()
            throw RecordingError.cancelled
        }
        Log.recording.notice("recording started: \(id.uuidString, privacy: .public) \(request.source.rawValue, privacy: .public) \(plan.pixelWidth)x\(plan.pixelHeight) \(plan.codec.rawValue, privacy: .public)\(plan.didSwitchToHEVC ? " (switched from H.264)" : "", privacy: .public) @\(fps) fps, \(quality.rawValue, privacy: .public), audio \(audioTracks.map(\.rawValue).joined(separator: "+"), privacy: .public)")
        return handle
    }

    /// Waits until the first frame is written (the media clock starts there).
    /// Returns `false` on timeout or when no session is running.
    func waitForFirstFrame(timeout: Duration = .seconds(5)) async -> Bool {
        guard let signal = session?.slot.current.firstFrame else { return false }
        return await signal.wait(timeout: timeout)
    }

    /// Moves the captured rect of the running session (window follow, plan
    /// §4.1; display-local points).
    func updateSourceRect(_ rect: CGRect) async throws {
        guard let session else { throw RecordingError.noActiveSession }
        try await session.source.updateSourceRect(rect)
    }

    // MARK: Pause, resume, restart (plan §4.6)

    /// Whether the running session is paused.
    var isPaused: Bool { session?.writer.isPaused ?? false }

    /// Media-time mapping of the current file (T0 + pauses, including an
    /// open pause); `nil` before the first frame or without a session. The
    /// event recorder (R4) maps host timestamps through it.
    var timeline: RecordingTimeline? { session?.writer.timeline }

    /// Stops writing (the source keeps running for an instant resume). The
    /// pause starts now; no-op when already paused.
    func pause() throws(RecordingError) {
        guard let session else { throw .noActiveSession }
        guard !session.writer.isPaused else { return }
        session.writer.pause(at: Self.hostNow())
        Log.recording.notice("recording paused at \(String(format: "%.3f", session.writer.mediaDuration(at: Self.hostNow())), privacy: .public) s")
    }

    /// Continues writing; the paused time is left out of the file. No-op
    /// when not paused.
    func resume() throws(RecordingError) {
        guard let session else { throw .noActiveSession }
        guard session.writer.isPaused else { return }
        session.writer.resume(at: Self.hostNow())
        Log.recording.notice("recording resumed, paused total \(String(format: "%.3f", session.writer.currentStats.pauseOffset.seconds), privacy: .public) s")
    }

    /// Throws away everything written so far and starts a fresh `screen.mov`
    /// in the same session folder, with the same target, source and options.
    /// The session is recording (not paused) afterwards; the result holds only
    /// what comes after the restart. Call `waitForFirstFrame()` again for the
    /// new media clock.
    func restart() throws(RecordingError) {
        guard var session else { throw .noActiveSession }
        let old = session.writer
        let configuration = old.configuration
        // Deletes `screen.mov`; the new writer recreates it.
        old.cancel()
        let writer: RecordingWriter
        do {
            writer = try RecordingWriter(configuration: configuration)
        } catch {
            let reason = (error as? RecordingError) ?? .writerFailed(error.localizedDescription)
            reportFailure(reason)
            throw reason
        }
        installFailureHandler(on: writer)
        session.slot.replace(with: writer)
        session.handle.startDate = .now
        self.session = session
        failure = nil
        Log.recording.notice("recording restarted: \(session.handle.id.uuidString, privacy: .public)")
    }

    private func installFailureHandler(on writer: RecordingWriter) {
        let writerID = ObjectIdentifier(writer)
        writer.setFailureHandler { [weak self] message in
            Task { await self?.reportFailure(.writerFailed(message), from: writerID) }
        }
    }

    nonisolated static func hostNow() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    // MARK: Stop

    /// Stops the source, finalizes `screen.mov`, writes `events.json` and
    /// returns the raw recording. Throws `.noActiveSession`, `.noFrames` (the
    /// session folder is removed) or writer errors.
    func stop() async throws -> RawRecording {
        guard let session else { throw RecordingError.noActiveSession }
        self.session = nil
        let stopTime = CMClockGetTime(CMClockGetHostTimeClock())
        // Samples up to the stop instant still in the source queues (audio
        // lags the video a little) are written; later ones are refused.
        session.writer.stopAccepting(after: stopTime)
        await session.source.stop()

        let summary: RecordingWriterSummary
        do {
            summary = try await session.writer.finish(at: stopTime)
        } catch {
            try? FileManager.default.removeItem(at: session.handle.sessionFolder)
            Log.recording.error("stop failed: \(String(describing: error), privacy: .public)")
            throw error
        }

        let eventsURL = session.handle.sessionFolder.appending(path: RawRecording.FileName.events)
        let metadata = RecordingMetadata(
            hostTimeOrigin: summary.sessionStart.seconds,
            pauses: summary.pauses,
            geometry: RecordingGeometryInfo(
                rect: session.resolved.globalRect.cgRect,
                displayID: session.resolved.displayID,
                scale: Double(session.resolved.scale),
                pixelWidth: session.plan.pixelWidth,
                pixelHeight: session.plan.pixelHeight
            ),
            cursorBakedIn: session.request.profile == .classic && session.request.options.showsCursor,
            droppedFrames: summary.droppedFrames
        )
        var writtenEventsURL: URL?
        do {
            try metadata.jsonData().write(to: eventsURL, options: .atomic)
            writtenEventsURL = eventsURL
        } catch {
            Log.recording.error("events.json: \(error.localizedDescription, privacy: .public)")
        }

        let handle = session.handle
        Log.recording.notice("recording stopped: \(String(format: "%.3f", summary.duration), privacy: .public) s, \(summary.framesWritten) frames, \(summary.droppedFrames) dropped")
        return RawRecording(
            id: handle.id,
            sessionFolder: handle.sessionFolder,
            eventsURL: writtenEventsURL,
            target: handle.target,
            profile: handle.profile,
            format: session.request.format,
            pixelSize: handle.pixelSize,
            pointSize: handle.pointSize,
            scale: handle.scale,
            fps: session.fps,
            duration: summary.duration,
            audioTracks: summary.audioTracks,
            startDate: handle.startDate
        )
    }

    /// Stops the source and deletes the session folder. No-op without a session.
    func discard() async {
        guard let session else { return }
        self.session = nil
        session.writer.stopAccepting()
        await session.source.stop()
        session.writer.cancel()
        try? FileManager.default.removeItem(at: session.handle.sessionFolder)
        Log.recording.notice("recording discarded: \(session.handle.id.uuidString, privacy: .public)")
    }

    // MARK: Stats

    /// Live numbers; `.zero` without a session.
    var stats: RecordingStats {
        guard let session else { return .zero }
        let writerStats = session.writer.currentStats
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let size = (try? FileManager.default.attributesOfItem(atPath: session.writer.configuration.outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return RecordingStats(
            duration: session.writer.mediaDuration(at: now),
            framesWritten: writerStats.framesWritten,
            droppedFrames: writerStats.droppedFrames,
            fileSize: size,
            microphoneLevel: session.audioTracks.contains(.microphone) ? session.meter.level(.microphone) : nil,
            systemAudioLevel: session.audioTracks.contains(.system) ? session.meter.level(.system) : nil,
            isPaused: writerStats.isPaused,
            microphoneSilent: session.audioTracks.contains(.microphone) && session.meter.isSilent(.microphone)
        )
    }

    /// The microphone is on and has stayed at or below −60 dBFS for at least
    /// 3 s (plan §1.4: the control bar shows a warning). `false` without a
    /// microphone.
    var isMicrophoneSilent: Bool {
        guard let session, session.audioTracks.contains(.microphone) else { return false }
        return session.meter.isSilent(.microphone)
    }

    /// Live meter of the running session (HUD, tests).
    var audioMeter: AudioLevelMeter? { session?.meter }

    /// The running session's handle.
    var currentHandle: RecordingHandle? { session?.handle }

    /// The first failure reported while recording (source or writer).
    var lastFailure: RecordingError? { failure }

    /// `writer`: the reporting writer; failures of a writer replaced by
    /// `restart()` are ignored.
    private func reportFailure(_ error: RecordingError, from writerID: ObjectIdentifier? = nil) {
        guard let session, failure == nil else { return }
        if let writerID, writerID != ObjectIdentifier(session.writer) { return }
        failure = error
        Log.recording.error("recording failed: \(error.description, privacy: .public)")
        onUnexpectedStop?(error)
    }

    // MARK: Pure helpers

    nonisolated static func usesSyntheticSource(_ request: RecordingRequest) -> Bool {
        #if DEBUG
        request.source == .synthetic
        #else
        false
        #endif
    }

    nonisolated static func makeSource(_ request: RecordingRequest) -> any RecordingFrameSource {
        #if DEBUG
        if request.source == .synthetic { return SyntheticFrameSource() }
        #endif
        return ScreenStreamSource(hidesDesktopIcons: request.options.hideDesktopIcons)
    }

    /// Audio tracks for a request, in track order (microphone, system). GIF
    /// recordings have no sound (plan §4.17), so they record none.
    nonisolated static func audioTracks(_ request: RecordingRequest) -> [AudioTrackKind] {
        guard request.format != .gif else { return [] }
        var kinds: [AudioTrackKind] = []
        if request.options.microphone != nil { kinds.append(.microphone) }
        if request.options.capturesSystemAudio { kinds.append(.system) }
        return kinds
    }

    /// Studio raw recordings are Ultra (plan §4.13).
    nonisolated static func effectiveQuality(_ request: RecordingRequest) -> VideoQuality {
        if request.profile == .studio { return .studioRaw }
        return VideoQuality(rawValue: request.options.quality.rawValue) ?? .default
    }

    /// Classic: the requested fps (1…120). Studio raw recordings follow the
    /// display up to 60 fps (`RecordingFrameRates.studioRawFPS`, plan §5.2);
    /// `displayRefreshRate` `nil` / 0 (unknown) = 60.
    nonisolated static func effectiveFPS(_ request: RecordingRequest, displayRefreshRate: Double? = nil) -> Int {
        guard request.profile == .studio else { return min(max(request.options.fps, 1), 120) }
        return RecordingFrameRates.studioRawFPS(displayRefreshRate: displayRefreshRate ?? 0)
    }

    /// The display's refresh rate; `nil` when unknown (some built-in panels report 0).
    nonisolated static func refreshRate(of displayID: CGDirectDisplayID) -> Double? {
        guard let mode = CGDisplayCopyDisplayMode(displayID), mode.refreshRate > 0 else { return nil }
        return mode.refreshRate
    }

    /// Encoder size and codec (H.264 over its limit switches to HEVC).
    nonisolated static func outputPlan(_ request: RecordingRequest, resolved: ResolvedRecordingTarget) -> RecordingOutputPlan {
        RecordingGeometry.plan(
            pointSize: resolved.pointSize,
            backingScale: Double(resolved.scale),
            scaleTo1x: request.options.scaleTo1x,
            maxResolution: RecordingResolutionCap(rawValue: request.options.maxResolution.rawValue) ?? .original,
            codec: VideoCodec(rawValue: request.options.codec.rawValue) ?? .h264
        )
    }

    /// Maps a target onto one display. Area and window rects are clipped to
    /// their display; the window's display is the one under its center.
    nonisolated static func resolve(
        _ target: RecordingTarget,
        layout: DisplayLayout,
        windowBounds: (CGWindowID) -> GlobalRect?
    ) throws -> ResolvedRecordingTarget {
        switch target {
        case let .display(displayID):
            guard let display = layout.display(withID: displayID),
                  let frame = ScreenGeometry.globalFrame(of: display, layout: layout)
            else { throw RecordingError.displayNotFound(displayID) }
            return ResolvedRecordingTarget(displayID: displayID, globalRect: frame, sourceRect: nil, scale: display.backingScaleFactor)

        case let .area(rect, displayID):
            guard let display = layout.display(withID: displayID),
                  let frame = ScreenGeometry.globalFrame(of: display, layout: layout)
            else { throw RecordingError.displayNotFound(displayID) }
            return try clipped(rect, to: display, frame: frame)

        case let .window(windowID):
            guard let bounds = windowBounds(windowID) else { throw RecordingError.windowNotFound(windowID) }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            guard let display = ScreenGeometry.display(containing: center, layout: layout)
                ?? ScreenGeometry.displays(intersecting: bounds, layout: layout).first,
                let frame = ScreenGeometry.globalFrame(of: display, layout: layout)
            else { throw RecordingError.invalidTarget }
            // R1.4 WindowFollower moves `sourceRect` while the window moves.
            return try clipped(bounds, to: display, frame: frame)
        }
    }

    private nonisolated static func clipped(_ rect: GlobalRect, to display: DisplayDescriptor, frame: GlobalRect) throws -> ResolvedRecordingTarget {
        let clipped = rect.cgRect.intersection(frame.cgRect)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw RecordingError.invalidTarget }
        let global = GlobalRect(origin: clipped.origin, size: clipped.size)
        let local = CGRect(x: clipped.minX - frame.minX, y: clipped.minY - frame.minY, width: clipped.width, height: clipped.height)
        return ResolvedRecordingTarget(displayID: display.id, globalRect: global, sourceRect: local, scale: display.backingScaleFactor)
    }

    /// Synthetic recordings without a matching display: scale 2, area rect as
    /// given, 1920×1080 pt for whole-display targets.
    nonisolated static func syntheticFallback(for target: RecordingTarget) -> ResolvedRecordingTarget? {
        switch target {
        case let .area(rect, displayID):
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            return ResolvedRecordingTarget(displayID: displayID, globalRect: rect, sourceRect: nil, scale: 2)
        case let .display(displayID):
            return ResolvedRecordingTarget(displayID: displayID, globalRect: GlobalRect(x: 0, y: 0, width: 1920, height: 1080), sourceRect: nil, scale: 2)
        case .window:
            return nil
        }
    }

    /// A window's frame in Quartz global points (`kCGWindowBounds`).
    nonisolated static func windowBounds(of windowID: CGWindowID) -> GlobalRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict)
        else { return nil }
        return GlobalRect(origin: bounds.origin, size: bounds.size)
    }

    /// Throws `.insufficientDiskSpace` under `minimumFreeBytes`; logs a
    /// warning under `lowDiskSpaceWarningBytes`.
    nonisolated static func checkDiskSpace(at url: URL) throws {
        guard let free = availableDiskSpace(at: url) else { return }
        if free < minimumFreeBytes { throw RecordingError.insufficientDiskSpace(availableBytes: free) }
        if free < lowDiskSpaceWarningBytes {
            Log.recording.warning("low disk space: \(free) bytes free")
        }
    }

    /// Free bytes on the volume holding `url` (or its nearest existing parent).
    nonisolated static func availableDiskSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// The session's current writer and first-frame signal, read by the source
/// handlers on the source queues and swapped by `RecordingEngine.restart()`.
nonisolated final class WriterSlot: @unchecked Sendable {
    // @unchecked: both fields guarded by `lock`.
    private let lock = NSLock()
    private var writerStorage: RecordingWriter
    private var signalStorage = FirstFrameSignal()

    init(writer: RecordingWriter) {
        writerStorage = writer
    }

    var current: (writer: RecordingWriter, firstFrame: FirstFrameSignal) {
        lock.withLock { (writerStorage, signalStorage) }
    }

    var writer: RecordingWriter { current.writer }

    /// Installs a new writer with a fresh first-frame signal.
    func replace(with writer: RecordingWriter) {
        lock.withLock {
            writerStorage = writer
            signalStorage = FirstFrameSignal()
        }
    }
}

/// One-shot "first frame written" flag, set from the source queue and polled
/// by `RecordingEngine.waitForFirstFrame(timeout:)`.
nonisolated final class FirstFrameSignal: @unchecked Sendable {
    // @unchecked: `isSet` guarded by `lock`.
    private let lock = NSLock()
    private var isSet = false

    func signal() {
        lock.withLock { isSet = true }
    }

    /// `true` once signalled; `false` after `timeout`.
    func wait(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if lock.withLock({ isSet }) { return true }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return lock.withLock { isSet }
    }
}
