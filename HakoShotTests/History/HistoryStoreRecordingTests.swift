import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// R0.4: `HistoryStore.addRecording` / `mediaURL(for:)` / the video byte cap
/// (`HistoryStore+Recording.swift`). Each test uses its own temporary root,
/// like `HistoryStoreTests`; nothing touches the real history folder.
@Suite("HistoryStore+Recording")
struct HistoryStoreRecordingTests {
    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "HakoShotHistoryRecordingTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// A small stand-in "media" file. `addRecording` only copies bytes, it
    /// never decodes them, so this doesn't need to be a real mp4/gif.
    private static func sourceMedia(extension ext: String, byteCount: Int = 32) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "HakoShotHistoryRecordingSource-\(UUID().uuidString).\(ext)")
        try Data(repeating: 0xAB, count: byteCount).write(to: url)
        return url
    }

    private static func result(
        format: RecordingFormat = .video,
        duration: Double = 12.5,
        width: CGFloat = 1280,
        height: CGFloat = 720,
        byteCount: Int = 32,
        date: Date = Date(timeIntervalSince1970: 1_790_164_800)
    ) throws -> RecordingResult {
        let media = try sourceMedia(extension: format.pathExtension, byteCount: byteCount)
        let thumbnail = PostCaptureFixture.image(pointWidth: 64, pointHeight: 36, scale: 1)
        return RecordingResult(
            fileURL: media, format: format, duration: duration,
            pixelSize: CGSize(width: width, height: height), thumbnail: thumbnail, date: date,
            targetKind: .area
        )
    }

    @Test func addRecordingCopiesMediaWritesPreviewAndIndexes() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)

        let item = try #require(await store.addRecording(try Self.result()))
        #expect(item.kind == .recording)
        #expect(item.mediaFormat == .video)
        #expect(item.durationSeconds == 12.5)
        #expect(item.pixelWidth == 1280 && item.pixelHeight == 720)

        let mediaName = try #require(item.mediaFileName)
        #expect(mediaName.hasSuffix(".mp4"))
        let mediaURL = try #require(store.mediaURL(for: item))
        #expect(FileManager.default.fileExists(atPath: mediaURL.path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: item.imageFileName).path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: item.thumbnailFileName).path))

        // A fresh store instance reads the persisted index.
        let reopened = HistoryStore(rootURL: root)
        #expect(await reopened.recent().map(\.id) == [item.id])
        #expect(await reopened.recent(filter: .recordings).map(\.id) == [item.id])
        #expect(await reopened.recent(filter: .screenshots).isEmpty)
    }

    @Test func addRecordingWorksForGIF() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)

        let item = try #require(await store.addRecording(try Self.result(format: .gif, duration: 3)))
        #expect(item.kind == .gif)
        #expect(item.mediaFormat == .gif)
        #expect(item.mediaFileName?.hasSuffix(".gif") == true)
    }

    @Test func addRecordingReturnsNilWhenHistoryIsOff() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let disabled = HistoryStore(rootURL: root, configuration: { HistoryConfiguration(isEnabled: false, retention: .oneMonth) })
        #expect(await disabled.addRecording(try Self.result()) == nil)

        let never = HistoryStore(rootURL: root, configuration: { HistoryConfiguration(isEnabled: true, retention: .never) })
        #expect(await never.addRecording(try Self.result()) == nil)
    }

    @Test func removingAnEntryDeletesItsMediaFile() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let item = try #require(await store.addRecording(try Self.result()))
        let mediaURL = try #require(store.mediaURL(for: item))
        #expect(FileManager.default.fileExists(atPath: mediaURL.path))

        await store.remove(id: item.id)
        #expect(!FileManager.default.fileExists(atPath: mediaURL.path))
    }

    @Test func enforceVideoByteCapEvictsOldestEntriesFirstAndDeletesFiles() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let base = Date(timeIntervalSince1970: 1_790_164_800)

        var items: [HistoryItem] = []
        for i in 0..<3 {
            let result = try Self.result(byteCount: 40, date: base.addingTimeInterval(Double(i) * 60))
            let item = try #require(await store.addRecording(result))
            items.append(item)
        }
        // Each media file is 40 bytes; a cap of 90 only fits the newest two (80 bytes).
        await store.enforceVideoByteCap(policy: VideoRetentionPolicy(byteCap: 90))

        let remaining = await store.recent(filter: .recordings)
        #expect(remaining.map(\.id) == [items[2].id, items[1].id])
        let evictedMediaURL = try #require(store.mediaURL(for: items[0]))
        #expect(!FileManager.default.fileExists(atPath: evictedMediaURL.path))
    }

    @Test func addRecordingDoesNotEvictUnderTheDefaultTenGigabyteCap() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let base = Date(timeIntervalSince1970: 1_790_164_800)
        for i in 0..<3 {
            let result = try Self.result(byteCount: 40, date: base.addingTimeInterval(Double(i) * 60))
            _ = try #require(await store.addRecording(result))
        }
        #expect(await store.recent(filter: .recordings).count == 3)
    }
}
