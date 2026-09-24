import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

enum HistoryFixture {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// 2026-09-23 12:00:00 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_164_800)

    static func item(
        daysAgo: Double = 0,
        kind: HistoryCaptureKind = .area,
        id: UUID = UUID()
    ) -> HistoryItem {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return HistoryItem(
            id: id,
            date: date,
            kind: kind,
            pixelWidth: 200,
            pixelHeight: 100,
            scale: 2,
            imageFileName: HistoryLayout.imageFileName(id: id, date: date, calendar: utc),
            thumbnailFileName: HistoryLayout.thumbnailFileName(id: id, date: date, calendar: utc)
        )
    }
}

@Suite("HistoryIndex")
struct HistoryIndexTests {
    @Test func listsNewestFirstRegardlessOfInsertOrder() {
        let old = HistoryFixture.item(daysAgo: 3)
        let new = HistoryFixture.item(daysAgo: 0)
        let mid = HistoryFixture.item(daysAgo: 1)
        var index = HistoryIndex()
        index.add(old)
        index.add(new)
        index.add(mid)
        #expect(index.items.map(\.id) == [new.id, mid.id, old.id])
        #expect(index.recent(limit: 2).map(\.id) == [new.id, mid.id])
        #expect(index.recent(limit: 0).isEmpty)
    }

    @Test func addReplacesSameIDAndRemoveWorks() {
        var item = HistoryFixture.item()
        var index = HistoryIndex(items: [item])
        item.savedFileURL = URL(fileURLWithPath: "/tmp/x.png")
        index.add(item)
        #expect(index.count == 1)
        #expect(index.item(id: item.id)?.savedFileURL?.path == "/tmp/x.png")
        #expect(index.remove(id: item.id)?.id == item.id)
        #expect(index.remove(id: item.id) == nil)
        #expect(index.isEmpty)
    }

    @Test func filterMatchesKinds() {
        let area = HistoryFixture.item(daysAgo: 0, kind: .area)
        let scroll = HistoryFixture.item(daysAgo: 1, kind: .scrolling)
        let text = HistoryFixture.item(daysAgo: 2, kind: .text)
        let window = HistoryFixture.item(daysAgo: 3, kind: .window)
        let index = HistoryIndex(items: [area, scroll, text, window])
        #expect(index.recent(filter: .screenshots).map(\.id) == [area.id, window.id])
        #expect(index.recent(filter: .scrolling).map(\.id) == [scroll.id])
        #expect(index.recent(filter: .text).map(\.id) == [text.id])
        #expect(index.recent(filter: .all).count == 4)
    }

    @Test func lastClosedIsMostRecentlyClosedNotNewestCapture() {
        let newer = HistoryFixture.item(daysAgo: 0)
        let older = HistoryFixture.item(daysAgo: 2)
        var index = HistoryIndex(items: [newer, older])
        #expect(index.lastClosed() == nil)
        index.markClosed(id: newer.id, at: HistoryFixture.now)
        index.markClosed(id: older.id, at: HistoryFixture.now.addingTimeInterval(10))
        #expect(index.lastClosed()?.id == older.id)
        index.markReopened(id: older.id)
        #expect(index.lastClosed()?.id == newer.id)
        #expect(index.item(id: older.id)?.closedDate == nil)
    }

    @Test func jsonRoundTrip() throws {
        var a = HistoryFixture.item(daysAgo: 0, kind: .scrolling)
        a.savedFileURL = URL(fileURLWithPath: "/Users/me/Desktop/HakoShot 1.png")
        a.projectFileName = "2026-09/x.hakoshot"
        let b = HistoryFixture.item(daysAgo: 5)
        var index = HistoryIndex(items: [a, b])
        index.markClosed(id: b.id, at: HistoryFixture.now)

        let loaded = HistoryIndex.load(from: try index.encoded())
        #expect(loaded.status == .ok)
        #expect(loaded.index == index)
    }

    @Test func fractionalDatesSurviveRoundTrip() throws {
        var item = HistoryFixture.item()
        item.date = HistoryFixture.now.addingTimeInterval(0.25)
        let loaded = HistoryIndex.load(from: try HistoryIndex(items: [item]).encoded())
        let date = try #require(loaded.index.items.first?.date)
        #expect(abs(date.timeIntervalSince(item.date)) < 0.001)
    }

    @Test func corruptOrTruncatedDataGivesEmptyIndex() throws {
        let index = HistoryIndex(items: [HistoryFixture.item(), HistoryFixture.item(daysAgo: 1)])
        let data = try index.encoded()
        let truncated = data.prefix(data.count / 2)
        #expect(HistoryIndex.load(from: Data(truncated)).status == .corrupt)
        #expect(HistoryIndex.load(from: Data()).status == .corrupt)
        #expect(HistoryIndex.load(from: Data("not json".utf8)).index.isEmpty)
        #expect(HistoryIndex.load(from: Data("[1,2]".utf8)).status == .corrupt)
    }

    @Test func badEntriesAreDroppedGoodOnesKept() throws {
        let good = HistoryFixture.item()
        let goodJSON = try #require(String(data: HistoryIndex(items: [good]).encoded(), encoding: .utf8))
        // Splice a broken entry (no id/date) and one with an unknown kind + missing optionals.
        let unknownID = UUID()
        let extra = """
        {"date":"2026-09-20T10:00:00Z","id":"\(unknownID.uuidString)","imageFileName":"2026-09/\(unknownID.uuidString).png","kind":"video"}
        """
        let spliced = goodJSON.replacingOccurrences(
            of: "\"items\" : [",
            with: "\"items\" : [ {\"garbage\": true}, \(extra),"
        )
        let result = HistoryIndex.load(from: Data(spliced.utf8))
        #expect(result.status == .partiallyRecovered(droppedCount: 1))
        #expect(result.index.count == 2)
        let recovered = try #require(result.index.item(id: unknownID))
        #expect(recovered.kind == .unknown)
        #expect(recovered.thumbnailFileName == "2026-09/\(unknownID.uuidString)-thumb.jpg")
        #expect(recovered.isClosed == false)
        #expect(result.index.item(id: good.id) == good)
    }
}

@Suite("RetentionPolicy")
struct RetentionPolicyTests {
    private let items = [0.5, 2, 6, 8, 29, 31, 60].map { HistoryFixture.item(daysAgo: $0) }

    private func purgedAges(_ retention: HistoryRetention) -> [Double] {
        let policy = RetentionPolicy(retention: retention, calendar: HistoryFixture.utc)
        return policy.itemsToPurge(in: items, now: HistoryFixture.now).map {
            (HistoryFixture.now.timeIntervalSince($0.date) / 86_400)
        }
    }

    @Test func defaultIsOneMonth() {
        #expect(HistoryRetention.default == .oneMonth)
        #expect(RetentionPolicy().retention == .oneMonth)
    }

    @Test func purgesByRetention() {
        // 2026-09-23 minus one calendar month = 2026-08-23 (31 days).
        #expect(purgedAges(.oneMonth) == [60])
        #expect(purgedAges(.oneWeek) == [8, 29, 31, 60])
        #expect(purgedAges(.oneDay) == [2, 6, 8, 29, 31, 60])
        #expect(purgedAges(.never).count == items.count)
        #expect(!HistoryRetention.never.keepsHistory)
    }

    @Test func boundaryIsExclusiveAndFutureItemsKept() {
        let policy = RetentionPolicy(retention: .oneDay, calendar: HistoryFixture.utc)
        #expect(!policy.isExpired(HistoryFixture.item(daysAgo: 1), now: HistoryFixture.now))
        #expect(policy.isExpired(HistoryFixture.item(daysAgo: 1.0001), now: HistoryFixture.now))
        #expect(!policy.isExpired(HistoryFixture.item(daysAgo: -3), now: HistoryFixture.now))
    }
}

@Suite("HistoryLayout")
struct HistoryLayoutTests {
    @Test func fileNamesUseMonthFolders() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let date = HistoryFixture.now
        let image = HistoryLayout.imageFileName(id: id, date: date, calendar: HistoryFixture.utc)
        #expect(image == "2026-09/11111111-2222-3333-4444-555555555555.png")
        #expect(HistoryLayout.thumbnailFileName(id: id, date: date, calendar: HistoryFixture.utc)
            == "2026-09/11111111-2222-3333-4444-555555555555-thumb.jpg")
        #expect(HistoryLayout.projectFileName(id: id, date: date, calendar: HistoryFixture.utc)
            == "2026-09/11111111-2222-3333-4444-555555555555.hakoshot")
        #expect(HistoryLayout.id(fromImageFileName: image) == id)
        #expect(HistoryLayout.id(fromImageFileName: "2026-09/\(id.uuidString)-thumb.jpg") == nil)
        #expect(HistoryLayout.id(fromImageFileName: "2026-09/foo.png") == nil)
    }
}

@Suite("HistoryThumbnail")
struct HistoryThumbnailTests {
    static func image(width: Int, height: Int) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        ctx.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    @Test func jpegThumbnailIsBoundedAndKeepsAspect() throws {
        let source = try #require(Self.image(width: 1600, height: 400))
        let data = try #require(HistoryThumbnail.jpegThumbnail(of: source))
        let decoded = try #require(HistoryThumbnail.downsample(data, maxPixelSize: 10_000))
        #expect(decoded.width == 480)
        #expect(decoded.height == 120)
    }

    @Test func smallImagesAreNotUpscaled() throws {
        let source = try #require(Self.image(width: 40, height: 30))
        let data = try #require(HistoryThumbnail.jpegThumbnail(of: source))
        let decoded = try #require(HistoryThumbnail.downsample(data, maxPixelSize: 10_000))
        #expect(decoded.width == 40)
        #expect(decoded.height == 30)
    }
}
