import AVFoundation
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Crash recovery (R7.4, plan §4.22). A "crashed" session is the bytes of a
/// `screen.mov` the engine is still writing, copied into a session folder of
/// a separate sessions root: exactly what is on disk if the process dies at
/// that moment (the engine itself is then discarded).
@Suite("Recording recovery", .serialized)
struct RecordingRecoveryTests {
    @Test(.timeLimit(.minutes(1)))
    func recoversCrashedSessionIntoHistory() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let id = try await scratch.makeCrashedSession()

        let history = HistoryStore(rootURL: scratch.history)
        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: history,
            fallbackFolder: scratch.fallback, minimumIdle: 0
        )

        #expect(report.recoveredCount == 1)
        #expect(report.message == "Recovered 1 recording")
        let recovered = try #require(report.recovered.first)
        #expect(recovered.sessionID == id)
        #expect(!recovered.wasStudio)
        #expect(recovered.result.raw == nil)
        #expect(recovered.result.fileURL.pathExtension == "mp4")
        #expect(recovered.result.duration > 0)

        let item = try #require(recovered.historyItem)
        #expect(recovered.result.historyID == item.id)
        let entries = await history.recent(filter: .recordings)
        #expect(entries.map(\.id) == [item.id])
        #expect(item.kind == .recording)
        let media = try #require(history.mediaURL(for: item))
        #expect(media == recovered.result.fileURL)

        let asset = AVURLAsset(url: media)
        #expect(try await asset.load(.isPlayable))
        #expect(try await asset.load(.duration).seconds > 0)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)

        #expect(!FileManager.default.fileExists(atPath: scratch.sessions.appending(path: id.uuidString).path))
    }

    @Test(.timeLimit(.minutes(1)))
    func historyOffKeepsTheFileInTheFallbackFolder() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let id = try await scratch.makeCrashedSession()

        let history = HistoryStore(rootURL: scratch.history, configuration: { HistoryConfiguration(isEnabled: false, retention: .oneMonth) })
        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: history,
            fallbackFolder: scratch.fallback, minimumIdle: 0
        )

        let recovered = try #require(report.recovered.first)
        #expect(recovered.historyItem == nil)
        #expect(recovered.result.historyID == nil)
        #expect(recovered.result.fileURL.deletingLastPathComponent().standardizedFileURL == scratch.fallback.standardizedFileURL)
        #expect(FileManager.default.fileExists(atPath: recovered.result.fileURL.path))
        #expect(!FileManager.default.fileExists(atPath: scratch.sessions.appending(path: id.uuidString).path))
    }

    @Test(.timeLimit(.minutes(1)))
    func activeSessionIsExcluded() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let id = try await scratch.makeCrashedSession()

        let history = HistoryStore(rootURL: scratch.history)
        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, excluding: [id], historyStore: history,
            fallbackFolder: scratch.fallback, minimumIdle: 0
        )

        #expect(report.recoveredCount == 0)
        #expect(report.message == nil)
        #expect(report.skipped.map(\.lastPathComponent) == [id.uuidString])
        #expect(FileManager.default.fileExists(atPath: scratch.sessions.appending(path: id.uuidString).appending(path: "screen.mov").path))
        #expect(await history.recent(filter: .recordings).isEmpty)
    }

    @Test func recentlyChangedSessionIsSkipped() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let folder = try scratch.makeFolder(age: 0)

        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: HistoryStore(rootURL: scratch.history),
            fallbackFolder: scratch.fallback
        )
        #expect(report.skipped.map(\.lastPathComponent) == [folder.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func emptyFoldersOlderThanADayAreDeletedNewerOnesKept() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        let old = try scratch.makeFolder(age: 2 * 24 * 3600)
        let oldEmptyMovie = try scratch.makeFolder(age: 2 * 24 * 3600, screenBytes: Data())
        let recent = try scratch.makeFolder(age: 3600)

        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: HistoryStore(rootURL: scratch.history),
            fallbackFolder: scratch.fallback, minimumIdle: 0
        )

        #expect(report.recoveredCount == 0)
        #expect(Set(report.deleted.map(\.lastPathComponent)) == [old.lastPathComponent, oldEmptyMovie.lastPathComponent])
        #expect(report.kept.map(\.lastPathComponent) == [recent.lastPathComponent])
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(!FileManager.default.fileExists(atPath: oldEmptyMovie.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
    }

    @Test func corruptFilesDoNotCrash() async throws {
        let scratch = try Scratch()
        defer { scratch.cleanup() }
        var garbage = Data(count: 64 * 1024)
        garbage.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8.random(in: 0...255) }
        }
        let oldCorrupt = try scratch.makeFolder(age: 3 * 24 * 3600, screenBytes: garbage)
        let newCorrupt = try scratch.makeFolder(age: 60, screenBytes: garbage)
        // A QuickTime header with nothing after it, plus a broken events.json.
        let truncated = try scratch.makeFolder(age: 60, screenBytes: Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20]))
        try Data("{ not json".utf8).write(to: truncated.appending(path: "events.json"))
        // Stray file and non-UUID folder in the root are left alone.
        try Data("x".utf8).write(to: scratch.sessions.appending(path: "stray.txt"))
        let other = scratch.sessions.appending(path: "not-a-session", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let report = await RecordingRecovery.recover(
            sessionsRoot: scratch.sessions, historyStore: HistoryStore(rootURL: scratch.history),
            fallbackFolder: scratch.fallback, minimumIdle: 0
        )

        #expect(report.recoveredCount == 0)
        #expect(report.deleted.map(\.lastPathComponent) == [oldCorrupt.lastPathComponent])
        #expect(Set(report.kept.map(\.lastPathComponent)) == [newCorrupt.lastPathComponent, truncated.lastPathComponent])
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(await RecordingRecovery.probe(newCorrupt.appending(path: "screen.mov")) == nil)
    }

    @Test func missingRootIsANoOp() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "HakoShotRecovery-missing-\(UUID().uuidString)")
        let report = await RecordingRecovery.recover(
            sessionsRoot: root, historyStore: HistoryStore(rootURL: root.appending(path: "History"))
        )
        #expect(report.recoveredCount == 0)
        #expect(report.deleted.isEmpty && report.kept.isEmpty && report.skipped.isEmpty)
    }

    @Test func messageCountsRecordings() {
        var report = RecoveryReport()
        #expect(report.message == nil)
        let image = Self.onePixel()
        let result = RecordingResult(fileURL: URL(filePath: "/tmp/a.mp4"), format: .video, duration: 1, pixelSize: .zero, thumbnail: image, targetKind: .area)
        report.recovered = [RecoveredRecording(sessionID: UUID(), result: result, historyItem: nil, wasStudio: false)]
        #expect(report.message == "Recovered 1 recording")
        report.recovered.append(report.recovered[0])
        #expect(report.message == "Recovered 2 recordings")
    }

    private static func onePixel() -> CGImage {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    // MARK: Fixture

    struct Scratch {
        let base: URL
        var sessions: URL { base.appending(path: "Recordings", directoryHint: .isDirectory) }
        var engineRoot: URL { base.appending(path: "Engine", directoryHint: .isDirectory) }
        var history: URL { base.appending(path: "History", directoryHint: .isDirectory) }
        var fallback: URL { base.appending(path: "Fallback", directoryHint: .isDirectory) }

        init() throws {
            base = FileManager.default.temporaryDirectory.appending(path: "HakoShotRecovery-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: base.appending(path: "Recordings"), withIntermediateDirectories: true)
        }

        func cleanup() { try? FileManager.default.removeItem(at: base) }

        /// Records ~3 s of synthetic video and, while the engine is still
        /// writing, copies `screen.mov` into a new session folder under
        /// `sessions` (the on-disk state of a crash). Returns its id.
        /// `profile` `.studio`: also copies `session.json` (the engine writes
        /// it at start), so recovery makes a `.hakostudio`.
        func makeCrashedSession(profile: RecordingProfile = .classic) async throws -> UUID {
            let engine = RecordingEngine(sessionsRoot: engineRoot)
            let request = RecordingRequest(
                target: .area(GlobalRect(x: 0, y: 0, width: 320, height: 180), displayID: CGMainDisplayID()),
                profile: profile,
                source: .synthetic
            )
            let handle = try await engine.start(request)
            try #require(await engine.waitForFirstFrame(), "no frame within 5 s")
            try await Task.sleep(for: .seconds(3))
            let id = UUID()
            let folder = sessions.appending(path: id.uuidString, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: handle.sessionFolder.appending(path: RawRecording.FileName.screen),
                to: folder.appending(path: RawRecording.FileName.screen)
            )
            if profile == .studio {
                try FileManager.default.copyItem(
                    at: handle.sessionFolder.appending(path: RawRecording.FileName.session),
                    to: folder.appending(path: RawRecording.FileName.session)
                )
            }
            await engine.discard()
            return id
        }

        /// A session folder (optionally with `screen.mov` bytes) whose
        /// modification dates are `age` seconds in the past.
        func makeFolder(age: TimeInterval, screenBytes: Data? = nil) throws -> URL {
            let folder = sessions.appending(path: UUID().uuidString, directoryHint: .isDirectory)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let date = Date.now.addingTimeInterval(-age)
            if let screenBytes {
                let screen = folder.appending(path: RawRecording.FileName.screen)
                try screenBytes.write(to: screen)
                try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: screen.path)
            }
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: folder.path)
            return folder
        }
    }
}
