import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Every test uses its own temporary root; nothing touches the real
/// `~/Library/Application Support/HakoShot/History`.
@Suite("HistoryStore")
struct HistoryStoreTests {
    private nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.withLock { value } }
        func advance(days: Double) { lock.withLock { value = value.addingTimeInterval(days * 86_400) } }
    }

    private static func tempRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "HakoShotHistoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private static func result(width: Int = 60, height: Int = 40, mode: CaptureMode = .area, date: Date) -> CaptureResult {
        let image = PostCaptureFixture.image(pointWidth: width, pointHeight: height, scale: 2)
        return CaptureResult(
            image: image, pointSize: CGSize(width: width, height: height), scale: 2, mode: mode, date: date
        )
    }

    private let start = Date(timeIntervalSince1970: 1_790_164_800)

    @Test func addWritesFilesAndIndexAndReadsBack() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)

        let item = try #require(await store.add(Self.result(date: start), savedURL: nil))
        #expect(item.kind == .area)
        #expect(item.pixelWidth == 120 && item.pixelHeight == 80 && item.scale == 2)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: item.imageFileName).path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: item.thumbnailFileName).path))
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "history.json").path))

        let image = try #require(await store.image(for: item))
        #expect(image.width == 120 && image.height == 80)
        #expect(await store.thumbnail(for: item) != nil)

        // A fresh store instance reads the persisted index.
        let reopened = HistoryStore(rootURL: root)
        #expect(await reopened.recent().map(\.id) == [item.id])
    }

    @Test func recentIsNewestFirstAndFiltered() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let a = try #require(await store.add(Self.result(date: start), savedURL: nil))
        let b = try #require(await store.add(Self.result(mode: .scrolling, date: start.addingTimeInterval(60)), savedURL: nil))
        #expect(await store.recent().map(\.id) == [b.id, a.id])
        #expect(await store.recent(limit: 1).map(\.id) == [b.id])
        #expect(await store.recent(filter: .scrolling).map(\.id) == [b.id])
        #expect(await store.recent(filter: .screenshots).map(\.id) == [a.id])
    }

    @Test func closedAndRestore() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let a = try #require(await store.add(Self.result(date: start), savedURL: nil))
        #expect(await store.lastClosed() == nil)
        await store.markClosed(id: a.id)
        #expect(await store.lastClosed()?.id == a.id)
        #expect(await HistoryStore(rootURL: root).lastClosed()?.id == a.id)
        await store.markReopened(id: a.id)
        #expect(await store.lastClosed() == nil)

        let saved = URL(fileURLWithPath: "/tmp/saved.png")
        await store.setSavedURL(saved, for: a.id)
        #expect(await store.item(id: a.id)?.savedFileURL == saved)
    }

    @Test func removeAndClearAllDeleteFiles() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(rootURL: root)
        let a = try #require(await store.add(Self.result(date: start), savedURL: nil))
        let b = try #require(await store.add(Self.result(date: start.addingTimeInterval(1)), savedURL: nil))

        await store.remove(id: a.id)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: a.imageFileName).path))
        #expect(await store.recent().map(\.id) == [b.id])

        await store.clearAll()
        #expect(await store.recent().isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(leftovers == ["history.json"])
    }

    @Test func purgeUsesRetentionAndInjectedClock() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = Clock(start)
        let store = HistoryStore(
            rootURL: root,
            configuration: { HistoryConfiguration(isEnabled: true, retention: .oneWeek) },
            now: { clock.now }
        )
        let old = try #require(await store.add(Self.result(date: start.addingTimeInterval(-10 * 86_400)), savedURL: nil))
        let fresh = try #require(await store.add(Self.result(date: start), savedURL: nil))

        #expect(await store.purgeExpired() == 1)
        #expect(await store.recent().map(\.id) == [fresh.id])
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: old.imageFileName).path))

        clock.advance(days: 8)
        #expect(await store.purgeExpired() == 1)
        #expect(await store.recent().isEmpty)
    }

    @Test func disabledOrNeverDoesNotRecord() async {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let off = HistoryStore(rootURL: root, configuration: { HistoryConfiguration(isEnabled: false, retention: .oneMonth) })
        #expect(await off.add(Self.result(date: start), savedURL: nil) == nil)
        let never = HistoryStore(rootURL: root, configuration: { HistoryConfiguration(isEnabled: true, retention: .never) })
        #expect(await never.add(Self.result(date: start), savedURL: nil) == nil)
        #expect(await never.recent().isEmpty)
    }

    @Test func corruptIndexIsMovedAsideAndFilesReadopted() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = HistoryStore(rootURL: root)
        let a = try #require(await first.add(Self.result(date: start), savedURL: nil))

        try Data("{ \"items\": [ {\"id\": ".utf8).write(to: root.appending(path: "history.json"))

        let second = HistoryStore(rootURL: root)
        let recovered = await second.recent()
        #expect(recovered.map(\.id) == [a.id])
        #expect(recovered.first?.pixelWidth == 120)
        #expect(recovered.first?.scale == 2)
        #expect(FileManager.default.fileExists(atPath: root.appending(path: "history.corrupt.json").path))
        #expect(await second.image(for: a.id) != nil)
    }

    @Test func entriesWithMissingOriginalAreDropped() async throws {
        let root = Self.tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = HistoryStore(rootURL: root)
        let a = try #require(await first.add(Self.result(date: start), savedURL: nil))
        let b = try #require(await first.add(Self.result(date: start.addingTimeInterval(1)), savedURL: nil))
        try FileManager.default.removeItem(at: root.appending(path: a.imageFileName))

        let second = HistoryStore(rootURL: root)
        #expect(await second.recent().map(\.id) == [b.id])
    }

    @Test func captureResultRoundTrip() throws {
        let item = HistoryItem(
            date: start, kind: .fullscreen, pixelWidth: 120, pixelHeight: 80, scale: 2,
            imageFileName: "x.png", thumbnailFileName: "x-thumb.jpg"
        )
        let image = PostCaptureFixture.image(pointWidth: 60, pointHeight: 40, scale: 2)
        let result = item.captureResult(image: image)
        #expect(result.pointSize == CGSize(width: 60, height: 40))
        #expect(result.mode == .fullscreen(.preferred))
        #expect(CaptureMode.scrolling.historyKind == .scrolling)
    }
}
