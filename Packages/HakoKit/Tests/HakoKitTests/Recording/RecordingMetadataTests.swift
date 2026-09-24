import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

enum RecordingMetadataFixture {
    static let sample = RecordingMetadata(
        hostTimeOrigin: 12_345.678,
        pauses: [12_350.0...12_352.5],
        geometry: RecordingGeometryInfo(
            rect: CGRect(x: 100, y: 120, width: 640, height: 360),
            displayID: 69_733_632,
            scale: 2,
            pixelWidth: 1280,
            pixelHeight: 720
        ),
        clicks: [
            RecordingClickEvent(time: 1.25, x: 10.5, y: 20, button: .left, isDown: true, clickCount: 2),
            RecordingClickEvent(time: 1.31, x: 10.5, y: 20, button: .left, isDown: false),
            RecordingClickEvent(time: 4.0, x: 300, y: 200, button: .right),
        ],
        keys: [
            RecordingKeyEvent(time: 2.0, keyCode: 3, modifierFlags: 0x0012_0000, characters: "f"),
            RecordingKeyEvent(time: 2.4, kind: .flagsChanged, keyCode: 55, modifierFlags: 0x0010_0000),
            RecordingKeyEvent(time: 2.5, keyCode: 6, modifierFlags: 0x0010_0000, characters: "z", isRepeat: true),
        ],
        cursorShapes: [
            RecordingCursorShape(hash: "a1b2", hotSpotX: 4, hotSpotY: 4, width: 17, height: 23),
            RecordingCursorShape(hash: "c3d4", hotSpotX: 8, hotSpotY: 8, width: 16, height: 16),
        ],
        cursorBakedIn: false,
        cameraTimeOffset: -0.033,
        droppedFrames: 3
    )
}

@Suite("RecordingMetadata")
struct RecordingMetadataTests {
    @Test func roundTrip() throws {
        let data = try RecordingMetadataFixture.sample.jsonData()
        let decoded = try RecordingMetadata(jsonData: data)
        #expect(decoded == RecordingMetadataFixture.sample)
        #expect(decoded.formatVersion == 1)
        #expect(decoded.cursorShapes[0].fileName == "cursors/a1b2.png")
        #expect(decoded.geometry.rect == CGRect(x: 100, y: 120, width: 640, height: 360))
        #expect(decoded.geometry.pixelsPerPoint == 2)
    }

    @Test func jsonShape() throws {
        let data = try RecordingMetadataFixture.sample.jsonData()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["formatVersion"] as? Int == 1)
        #expect((object["pauses"] as? [[Double]]) == [[12_350.0, 12_352.5]])
        #expect((object["clicks"] as? [Any])?.count == 3)
        // Deterministic output (sorted keys).
        #expect(try RecordingMetadataFixture.sample.jsonData() == data)
    }

    @Test func noCameraOmitsOffset() throws {
        var meta = RecordingMetadataFixture.sample
        meta.cameraTimeOffset = nil
        let data = try meta.jsonData()
        #expect(!String(decoding: data, as: UTF8.self).contains("cameraTimeOffset"))
        #expect(try RecordingMetadata(jsonData: data).cameraTimeOffset == nil)
    }

    @Test func minimalV1FileDecodesWithDefaults() throws {
        let json = #"""
        {
          "formatVersion": 1,
          "geometry": { "x": 0, "y": 0, "width": 100, "height": 50, "displayID": 1,
                        "scale": 1, "pixelWidth": 100, "pixelHeight": 50 },
          "clicks": [ { "time": 0.5, "x": 1, "y": 2 } ],
          "keys": [ { "time": 0.7, "keyCode": 36 } ],
          "somethingFromTheFuture": true
        }
        """#
        let meta = try RecordingMetadata(jsonData: Data(json.utf8))
        #expect(meta.hostTimeOrigin == 0)
        #expect(meta.pauses.isEmpty)
        #expect(meta.clicks == [RecordingClickEvent(time: 0.5, x: 1, y: 2)])
        #expect(meta.keys == [RecordingKeyEvent(time: 0.7, keyCode: 36)])
        #expect(meta.cursorShapes.isEmpty)
        #expect(!meta.cursorBakedIn)
        #expect(meta.droppedFrames == 0)
    }

    @Test func newerFormatVersionIsRejected() {
        let json = #"{"formatVersion": 2, "geometry": {}}"#
        #expect(throws: RecordingMetadataError.unsupportedFormatVersion(2)) {
            try RecordingMetadata(jsonData: Data(json.utf8))
        }
    }

    @Test func missingGeometryFails() {
        #expect(throws: DecodingError.self) {
            try RecordingMetadata(jsonData: Data(#"{"formatVersion": 1}"#.utf8))
        }
    }
}

@Suite("CursorTrackCodec")
struct CursorTrackCodecTests {
    static let samples: [CursorSample] = [
        CursorSample(time: 0, x: 0, y: 0),
        CursorSample(time: 1.0 / 60, x: 10.25, y: -3.5, shapeIndex: 1, flags: [.leftDown]),
        CursorSample(time: 3600.123456789, x: 5119.5, y: 2879.75, shapeIndex: 65_535, flags: [.rightDown, .otherDown, .hidden]),
    ]

    @Test func roundTrip() throws {
        let data = CursorTrackCodec.encode(Self.samples)
        #expect(data.count == 16 + 3 * 20)
        #expect(try CursorTrackCodec.decode(data) == Self.samples)
        #expect(try CursorTrackCodec.decode(CursorTrackCodec.encode([])).isEmpty)
    }

    @Test func headerLayoutIsLittleEndian() {
        let data = [UInt8](CursorTrackCodec.encode(Self.samples))
        #expect(Array(data[0..<4]) == Array("HKCR".utf8))
        #expect(Array(data[4..<8]) == [1, 0, 0, 0])
        #expect(Array(data[8..<16]) == [3, 0, 0, 0, 0, 0, 0, 0])
        // Second record: t = 1/60 as Float64 LE, then x = 10.25 as Float32 LE.
        let record = Array(data[36..<56])
        var t: UInt64 = 0
        for i in 0..<8 { t |= UInt64(record[i]) << (8 * i) }
        #expect(Double(bitPattern: t) == 1.0 / 60)
        var x: UInt32 = 0
        for i in 0..<4 { x |= UInt32(record[8 + i]) << (8 * i) }
        #expect(Float(bitPattern: x) == 10.25)
        #expect(Array(record[16..<20]) == [1, 0, 1, 0])
    }

    @Test func streamingWithUnknownCountReadsCompleteRecords() throws {
        var data = CursorTrackCodec.header(recordCount: nil)
        for sample in Self.samples { data.append(CursorTrackCodec.record(sample)) }
        data.append(contentsOf: [0xAA, 0xBB, 0xCC]) // crash mid-record
        #expect(try CursorTrackCodec.decode(data) == Self.samples)
        // Patch the count at stop.
        data.replaceSubrange(8..<12, with: CursorTrackCodec.countField(2))
        #expect(try CursorTrackCodec.decode(data) == Array(Self.samples.prefix(2)))
    }

    @Test func errors() {
        #expect(throws: CursorTrackError.truncatedHeader) {
            try CursorTrackCodec.decode(Data([0x48, 0x4B]))
        }
        var bad = CursorTrackCodec.encode(Self.samples)
        bad[0] = 0x58
        #expect(throws: CursorTrackError.badMagic) { try CursorTrackCodec.decode(bad) }

        var future = CursorTrackCodec.encode(Self.samples)
        future[4] = 2
        #expect(throws: CursorTrackError.unsupportedVersion(2)) { try CursorTrackCodec.decode(future) }

        let short = CursorTrackCodec.encode(Self.samples).prefix(16 + 2 * 20 + 5)
        #expect(throws: CursorTrackError.truncatedRecords(expected: 3, available: 2)) {
            try CursorTrackCodec.decode(Data(short))
        }
    }

    @Test func knownCountNeverEqualsUnknownSentinel() {
        let field = [UInt8](CursorTrackCodec.countField(Int(UInt32.max)))
        #expect(field == [0xFE, 0xFF, 0xFF, 0xFF])
        #expect([UInt8](CursorTrackCodec.countField(nil)) == [0xFF, 0xFF, 0xFF, 0xFF])
    }
}
