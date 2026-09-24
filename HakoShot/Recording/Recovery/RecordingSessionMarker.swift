import CoreGraphics
import Foundation
import HakoKit
import os

/// `session.json` in a session folder (plan §4.22): what crash recovery needs
/// before `events.json` exists (the engine writes that only at stop): the
/// profile (Studio sessions are recovered as `.hakostudio`), the format and
/// the recorded rect. Written once by `RecordingEngine.start`.
nonisolated struct RecordingSessionMarker: Codable, Sendable, Equatable {
    var profile: RecordingProfile
    var format: RecordingFormat
    /// Recorded rect, Quartz global points: `[x, y, width, height]`.
    var rect: [Double]
    var displayID: UInt32
    var scale: Double
    var pixelWidth: Int
    var pixelHeight: Int
    var fps: Int
    var showsCursor: Bool
    var audioTracks: [AudioTrackKind]
    var startDate: Date

    init(
        profile: RecordingProfile, format: RecordingFormat, rect: CGRect, displayID: UInt32, scale: Double,
        pixelWidth: Int, pixelHeight: Int, fps: Int, showsCursor: Bool, audioTracks: [AudioTrackKind], startDate: Date = .now
    ) {
        self.profile = profile
        self.format = format
        self.rect = [rect.minX, rect.minY, rect.width, rect.height]
        self.displayID = displayID
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fps = fps
        self.showsCursor = showsCursor
        self.audioTracks = audioTracks
        self.startDate = startDate
    }

    init(request: RecordingRequest, resolved: ResolvedRecordingTarget, plan: RecordingOutputPlan, fps: Int, audioTracks: [AudioTrackKind]) {
        self.init(
            profile: request.profile,
            format: request.format,
            rect: resolved.globalRect.cgRect,
            displayID: resolved.displayID,
            scale: Double(resolved.scale),
            pixelWidth: plan.pixelWidth,
            pixelHeight: plan.pixelHeight,
            fps: fps,
            showsCursor: request.profile == .classic && request.options.showsCursor,
            audioTracks: audioTracks
        )
    }

    var cgRect: CGRect {
        rect.count == 4 ? CGRect(x: rect[0], y: rect[1], width: rect[2], height: rect[3]) : .zero
    }

    /// What `events.json` would have said without events (crash before stop):
    /// the geometry and whether the cursor is in the pixels. Media time 0 is
    /// unknown (`hostTimeOrigin` 0); `cursor.bin` is already in media time.
    var fallbackMetadata: RecordingMetadata {
        RecordingMetadata(
            hostTimeOrigin: 0,
            geometry: RecordingGeometryInfo(rect: cgRect, displayID: displayID, scale: scale, pixelWidth: pixelWidth, pixelHeight: pixelHeight),
            cursorBakedIn: profile == .classic && showsCursor
        )
    }

    func write(toSessionFolder folder: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(self).write(to: folder.appending(path: RawRecording.FileName.session), options: .atomic)
        } catch {
            Log.recording.error("session.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func read(inSessionFolder folder: URL) -> RecordingSessionMarker? {
        guard let data = try? Data(contentsOf: folder.appending(path: RawRecording.FileName.session)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingSessionMarker.self, from: data)
    }
}
