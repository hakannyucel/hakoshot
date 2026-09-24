@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import os

/// Turns a stopped session's raw `screen.mov` (fragmented QuickTime) into the
/// `.mp4` the user gets (kayit-teknik-plan §4.14).
///
/// Video is never re-encoded. Audio follows `AudioMixPlan` (plan §4.7): when
/// the raw tracks can be copied as they are (no audio, or tracks that need no
/// mix / mono / silent-channel fix) the whole file is a fast passthrough
/// remux; otherwise `AudioMixExporter` copies the video and writes mixed AAC
/// (48 kHz, 128 kbps stereo / 64 kbps mono). `shouldOptimizeForNetworkUse`
/// puts the `moov` atom first so previews start fast.
nonisolated enum RecordingFinalizer {
    /// Name of the finished file inside the session folder (moved out by
    /// `RecordingOutputRouter` before the folder is deleted).
    static let outputFileName = "recording.mp4"

    /// Converts `raw.screenURL` to `destination` (default: `<session>/recording.mp4`)
    /// with `audio` (the recording's "Audio tracks" / mono choice), makes the
    /// thumbnail and returns the result (no history id yet).
    static func finalize(
        _ raw: RawRecording,
        audio: AudioMixSettings = .standard,
        to destination: URL? = nil
    ) async throws -> RecordingResult {
        let output = destination ?? raw.sessionFolder.appending(path: outputFileName)
        let started = Date.now
        try await convert(raw.screenURL, to: output, roles: raw.audioTracks, audio: audio)

        let asset = AVURLAsset(url: output)
        let duration: Double
        let pixelSize: CGSize
        do {
            duration = try await asset.load(.duration).seconds
            let track = try await asset.loadTracks(withMediaType: .video).first
            if let track {
                let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
                let size = natural.applying(transform)
                pixelSize = CGSize(width: abs(size.width), height: abs(size.height))
            } else {
                pixelSize = raw.pixelSize
            }
        } catch {
            throw RecordingError.finalizeFailed("reading remuxed file: \(error.localizedDescription)")
        }
        let thumbnail = try await RecordingThumbnailer.thumbnail(for: output, duration: duration)
        Log.recording.notice("finalized \(output.lastPathComponent, privacy: .public): \(String(format: "%.3f", duration), privacy: .public) s, \(Int(pixelSize.width))x\(Int(pixelSize.height)) in \(String(format: "%.2f", Date.now.timeIntervalSince(started)), privacy: .public) s")
        return RecordingResult(
            fileURL: output,
            format: .video,
            duration: duration.isFinite ? duration : raw.duration,
            pixelSize: pixelSize,
            thumbnail: thumbnail,
            date: raw.startDate,
            targetKind: raw.target.kind,
            raw: raw
        )
    }

    /// What `convert` did (logs, DEBUG, tests).
    struct Report: Sendable, Equatable {
        var plan: AudioMixPlan
        /// `false` = passthrough remux.
        var mixed: Bool
    }

    /// `source` (raw .mov) → `destination` (.mp4, replaced). `roles` names
    /// the source's audio tracks in file order; when it doesn't match the
    /// track count they are taken as microphone, system (plan §4.7 order),
    /// a single track as `.microphone` only if `roles` says so, else `.system`.
    @discardableResult
    static func convert(_ source: URL, to destination: URL, roles: [AudioTrackKind], audio: AudioMixSettings) async throws -> Report {
        let asset = AVURLAsset(url: source)
        let plan: AudioMixPlan
        let videoTrack: AVAssetTrack?
        let audioTracks: [AVAssetTrack]
        do {
            videoTrack = try await asset.loadTracks(withMediaType: .video).first
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let trackRoles = Self.roles(roles, trackCount: audioTracks.count)
            var inputs: [AudioMixInput] = []
            for (track, role) in zip(audioTracks, trackRoles) {
                let channels = try await AudioMixExporter.channelCount(of: track)
                // Only the microphone gets the silent-channel check (one extra decode pass).
                let peaks = role == .microphone && channels == 2
                    ? try await AudioMixExporter.channelPeaks(of: track, in: asset, channelCount: channels)
                    : nil
                inputs.append(AudioMixInput(role: role, channelCount: channels, channelPeaks: peaks))
            }
            plan = AudioMixPlan(settings: audio, inputs: inputs)
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.finalizeFailed("reading raw file: \(error.localizedDescription)")
        }

        guard plan.needsProcessing else {
            try await remux(source, to: destination)
            return Report(plan: plan, mixed: false)
        }
        if !plan.silentChannelFixes.isEmpty {
            Log.recording.notice("finalize: microphone has one silent channel; using the other on both")
        }
        do {
            try await AudioMixExporter.export(asset: asset, videoTrack: videoTrack, audioTracks: audioTracks, plan: plan, to: destination)
        } catch let error as RecordingError {
            throw error
        } catch {
            throw RecordingError.finalizeFailed("audio mix: \(error.localizedDescription)")
        }
        Log.recording.notice("finalize: mixed \(audioTracks.count) audio track(s) into \(plan.outputs.count) (\(plan.outputs.map { "\($0.channelCount) ch" }.joined(separator: ", "), privacy: .public))")
        return Report(plan: plan, mixed: true)
    }

    /// HakoKit roles for the file's audio tracks (see `convert`).
    static func roles(_ kinds: [AudioTrackKind], trackCount: Int) -> [AudioMixTrackRole] {
        if kinds.count == trackCount { return kinds.map { $0 == .microphone ? .microphone : .system } }
        switch trackCount {
        case 0: return []
        case 1: return [.system]
        default: return [.microphone] + Array(repeating: .system, count: trackCount - 1)
        }
    }

    /// Passthrough remux of every track of `source` into an `.mp4` at
    /// `destination` (replaced if it exists). Throws `RecordingError.finalizeFailed`.
    static func remux(_ source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw RecordingError.finalizeFailed("no passthrough export session")
        }
        session.shouldOptimizeForNetworkUse = true
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try await session.export(to: destination, as: .mp4)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw RecordingError.finalizeFailed("remux: \(error.localizedDescription)")
        }
    }
}

extension AudioMixSettings {
    /// The recording's "Audio tracks" and "Record audio in mono" choices.
    nonisolated init(_ options: RecordingOptions) {
        self.init(layout: AudioMixLayout(rawValue: options.audioTrackLayout.rawValue) ?? .single, mono: options.monoAudio)
    }
}
