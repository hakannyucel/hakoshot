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

    /// A recorded video (or GIF) entry, with the R0.4 video fields filled in.
    static func videoItem(
        daysAgo: Double = 0,
        kind: HistoryCaptureKind = .recording,
        format: HistoryMediaFormat = .video,
        duration: Double = 3.5,
        id: UUID = UUID()
    ) -> HistoryItem {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        return HistoryItem(
            id: id,
            date: date,
            kind: kind,
            pixelWidth: 1280,
            pixelHeight: 720,
            scale: 2,
            imageFileName: HistoryLayout.imageFileName(id: id, date: date, calendar: utc),
            thumbnailFileName: HistoryLayout.thumbnailFileName(id: id, date: date, calendar: utc),
            mediaFileName: HistoryLayout.mediaFileName(id: id, date: date, format: format, calendar: utc),
            durationSeconds: duration,
            mediaFormat: format
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

// MARK: - R0.4: video / GIF / Studio history entries

@Suite("HistoryItem video fields")
struct HistoryItemVideoTests {
    @Test func decodesOldEntryWithoutVideoFields() throws {
        // A pre-R0.4 index entry: no mediaFileName/durationSeconds/mediaFormat/
        // eventsFileName/studioPackageName keys at all.
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","date":"2026-09-20T10:00:00Z",
         "imageFileName":"2026-09/\(id.uuidString).png","kind":"area",
         "pixelWidth":200,"pixelHeight":100,"scale":2}
        """
        let item = try HistoryIndex.makeDecoder().decode(HistoryItem.self, from: Data(json.utf8))
        #expect(item.mediaFileName == nil)
        #expect(item.durationSeconds == nil)
        #expect(item.mediaFormat == nil)
        #expect(item.eventsFileName == nil)
        #expect(item.studioPackageName == nil)
        #expect(item.kind == .area)
        #expect(item.ownedFileNames == [item.imageFileName, item.thumbnailFileName])
    }

    @Test func encodesAndDecodesVideoFieldsRoundTrip() throws {
        let video = HistoryFixture.videoItem(kind: .recording, format: .video, duration: 12.25)
        let data = try HistoryIndex.makeEncoder().encode(video)
        let decoded = try HistoryIndex.makeDecoder().decode(HistoryItem.self, from: data)
        #expect(decoded == video)
        #expect(decoded.mediaFileName == video.mediaFileName)
        #expect(decoded.durationSeconds == 12.25)
        #expect(decoded.mediaFormat == .video)
    }

    @Test func unknownKindAndMediaFormatFallBackInsteadOfThrowing() throws {
        // Forward compatibility: a future build's `kind`/`mediaFormat` raw
        // values, and any extra top-level keys, must not fail decoding.
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","date":"2026-09-20T10:00:00Z",
         "imageFileName":"2026-09/\(id.uuidString).png","kind":"someFutureKind",
         "mediaFormat":"webm","somethingNew":true}
        """
        let item = try HistoryIndex.makeDecoder().decode(HistoryItem.self, from: Data(json.utf8))
        #expect(item.kind == .unknown)
        #expect(item.mediaFormat == nil)
    }

    @Test func ownedFileNamesIncludesMediaEventsAndStudioPackage() {
        var item = HistoryFixture.videoItem()
        #expect(item.ownedFileNames.contains(item.mediaFileName!))
        item.eventsFileName = "2026-09/x-events.json"
        item.studioPackageName = "2026-09/x.hakostudio"
        #expect(item.ownedFileNames.contains(item.eventsFileName!))
        #expect(item.ownedFileNames.contains(item.studioPackageName!))
        #expect(item.ownedFileNames.count == 5)
    }

    @Test func captureKindIsVideo() {
        #expect(HistoryCaptureKind.recording.isVideo)
        #expect(HistoryCaptureKind.gif.isVideo)
        #expect(HistoryCaptureKind.studio.isVideo)
        #expect(!HistoryCaptureKind.area.isVideo)
        #expect(!HistoryCaptureKind.scrolling.isVideo)
    }
}

@Suite("HistoryFilter recordings")
struct HistoryFilterRecordingsTests {
    @Test func recordingsMatchesVideoGifAndStudioOnly() {
        #expect(HistoryFilter.recordings.matches(.recording))
        #expect(HistoryFilter.recordings.matches(.gif))
        #expect(HistoryFilter.recordings.matches(.studio))
        #expect(!HistoryFilter.recordings.matches(.area))
        #expect(!HistoryFilter.recordings.matches(.scrolling))
        #expect(!HistoryFilter.recordings.matches(.text))
    }

    @Test func screenshotsExcludesVideoKinds() {
        #expect(!HistoryFilter.screenshots.matches(.recording))
        #expect(!HistoryFilter.screenshots.matches(.gif))
        #expect(!HistoryFilter.screenshots.matches(.studio))
        #expect(HistoryFilter.screenshots.matches(.area))
        #expect(HistoryFilter.screenshots.matches(.window))
    }

    @Test func indexRecentFiltersToRecordings() {
        let recording = HistoryFixture.videoItem(kind: .recording)
        let gif = HistoryFixture.videoItem(daysAgo: 1, kind: .gif, format: .gif)
        let studio = HistoryFixture.videoItem(daysAgo: 2, kind: .studio)
        let screenshot = HistoryFixture.item(daysAgo: 3)
        let index = HistoryIndex(items: [recording, gif, studio, screenshot])
        let ids = Set(index.recent(filter: .recordings).map(\.id))
        #expect(ids == Set([recording.id, gif.id, studio.id]))
    }
}

@Suite("VideoRetentionPolicy")
struct VideoRetentionPolicyTests {
    @Test func keepsEverythingUnderTheCap() {
        let items = (0..<3).map { HistoryFixture.videoItem(daysAgo: Double($0)) }
        let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Int64(1_000)) })
        let policy = VideoRetentionPolicy(byteCap: 1_000_000)
        #expect(policy.itemsToEvict(in: items, sizes: sizes).isEmpty)
    }

    @Test func evictsOldestFirstUntilUnderCap() {
        let oldest = HistoryFixture.videoItem(daysAgo: 5)
        let middle = HistoryFixture.videoItem(daysAgo: 2)
        let newest = HistoryFixture.videoItem(daysAgo: 0)
        let sizes: [UUID: Int64] = [oldest.id: 500, middle.id: 500, newest.id: 500]
        let policy = VideoRetentionPolicy(byteCap: 800)
        // 1500 total, cap 800: evict oldest (500) -> 1000, still over cap;
        // evict middle (500) -> 500, under cap, stop. Newest is kept.
        let evicted = policy.itemsToEvict(in: [newest, middle, oldest], sizes: sizes)
        #expect(evicted.map(\.id) == [oldest.id, middle.id])
    }

    @Test func ignoresEntriesMissingFromSizes() {
        let known = HistoryFixture.videoItem(daysAgo: 3)
        let unknown = HistoryFixture.videoItem(daysAgo: 5)
        let sizes: [UUID: Int64] = [known.id: 2_000_000_000]
        let policy = VideoRetentionPolicy(byteCap: 1_000_000_000)
        let evicted = policy.itemsToEvict(in: [known, unknown], sizes: sizes)
        #expect(evicted.map(\.id) == [known.id])
    }

    @Test func defaultCapIsTenGigabytes() {
        #expect(VideoRetentionPolicy().byteCap == 10_000_000_000)
        #expect(HistoryRetention.videoByteCap == 10_000_000_000)
    }

    @Test func exactlyAtCapDoesNotEvict() {
        let items = (0..<2).map { HistoryFixture.videoItem(daysAgo: Double($0)) }
        let sizes = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Int64(500)) })
        let policy = VideoRetentionPolicy(byteCap: 1_000)
        #expect(policy.itemsToEvict(in: items, sizes: sizes).isEmpty)
    }
}

@Suite("HistoryLayout video naming")
struct HistoryLayoutVideoTests {
    @Test func mediaFileNamesUseFormatExtension() throws {
        let id = try #require(UUID(uuidString: "11111111-2222-3333-4444-555555555555"))
        let date = HistoryFixture.now
        #expect(HistoryLayout.mediaFileName(id: id, date: date, format: .video, calendar: HistoryFixture.utc)
            == "2026-09/11111111-2222-3333-4444-555555555555.mp4")
        #expect(HistoryLayout.mediaFileName(id: id, date: date, format: .gif, calendar: HistoryFixture.utc)
            == "2026-09/11111111-2222-3333-4444-555555555555.gif")
        #expect(HistoryLayout.eventsFileName(id: id, date: date, calendar: HistoryFixture.utc)
            == "2026-09/11111111-2222-3333-4444-555555555555-events.json")
        #expect(HistoryLayout.studioPackageName(id: id, date: date, calendar: HistoryFixture.utc)
            == "2026-09/11111111-2222-3333-4444-555555555555.hakostudio")
    }
}
