import Foundation

/// Mouse buttons held during a cursor sample.
public struct CursorSampleFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let leftDown = CursorSampleFlags(rawValue: 1 << 0)
    public static let rightDown = CursorSampleFlags(rawValue: 1 << 1)
    public static let otherDown = CursorSampleFlags(rawValue: 1 << 2)
    /// The cursor was hidden (e.g. while typing) at this sample.
    public static let hidden = CursorSampleFlags(rawValue: 1 << 3)
}

/// One cursor position sample.
public struct CursorSample: Sendable, Hashable {
    /// Media seconds.
    public var time: Double
    /// Points relative to the recording rect's top-left.
    public var x: Float
    public var y: Float
    /// Index into `RecordingMetadata.cursorShapes`.
    public var shapeIndex: UInt16
    public var flags: CursorSampleFlags

    public init(time: Double, x: Float, y: Float, shapeIndex: UInt16 = 0, flags: CursorSampleFlags = []) {
        self.time = time
        self.x = x
        self.y = y
        self.shapeIndex = shapeIndex
        self.flags = flags
    }
}

public enum CursorTrackError: Error, Sendable, Equatable {
    /// Fewer than 16 bytes.
    case truncatedHeader
    /// First 4 bytes are not `"HKCR"`.
    case badMagic
    /// Written by a newer HakoShot.
    case unsupportedVersion(UInt16)
    /// Header count says more records than the file holds.
    case truncatedRecords(expected: Int, available: Int)
}

/// `cursor.bin` binary format (plan §4.18). Little-endian.
///
/// Header, 16 bytes:
/// ```
/// 0  "HKCR"            4 bytes
/// 4  version  UInt16   (1)
/// 6  reserved UInt16   (0)
/// 8  count    UInt32   (record count; 0xFFFFFFFF = unknown / still recording)
/// 12 reserved UInt32   (0)
/// ```
/// Record, 20 bytes: `Float64 t`, `Float32 x`, `Float32 y`, `UInt16 shapeIndex`,
/// `UInt16 flags`.
///
/// Streaming: the recorder writes `header(recordCount: nil)`, appends
/// `record(_:)` bytes, and on stop overwrites bytes 8..<12 with
/// `countField(_:)`. A file left with the unknown count (crash) decodes every
/// complete record.
public enum CursorTrackCodec {
    public static let fileName = "cursor.bin"
    public static let magic: [UInt8] = Array("HKCR".utf8)
    public static let currentVersion: UInt16 = 1
    public static let headerSize = 16
    public static let recordSize = 20
    /// Byte offset of the count field (for patching after streaming).
    public static let countOffset = 8
    public static let unknownCount: UInt32 = .max

    /// Header bytes; `nil` count writes `unknownCount`.
    public static func header(recordCount: Int?) -> Data {
        var data = Data(capacity: headerSize)
        data.append(contentsOf: magic)
        append(currentVersion, to: &data)
        append(UInt16(0), to: &data)
        data.append(countField(recordCount))
        append(UInt32(0), to: &data)
        return data
    }

    /// 4-byte little-endian count field.
    public static func countField(_ recordCount: Int?) -> Data {
        var data = Data(capacity: 4)
        // A known count never collides with the "unknown" sentinel.
        let value = recordCount.map { min(UInt32(clamping: $0), unknownCount - 1) } ?? unknownCount
        append(value, to: &data)
        return data
    }

    /// One 20-byte record.
    public static func record(_ sample: CursorSample) -> Data {
        var data = Data(capacity: recordSize)
        append(sample.time.bitPattern, to: &data)
        append(sample.x.bitPattern, to: &data)
        append(sample.y.bitPattern, to: &data)
        append(sample.shapeIndex, to: &data)
        append(sample.flags.rawValue, to: &data)
        return data
    }

    /// A complete file.
    public static func encode(_ samples: [CursorSample]) -> Data {
        var data = header(recordCount: samples.count)
        data.reserveCapacity(headerSize + samples.count * recordSize)
        for sample in samples { data.append(record(sample)) }
        return data
    }

    /// Decodes a file. With a known count, trailing bytes are ignored and a
    /// short file throws `truncatedRecords`. With `unknownCount`, every
    /// complete record is returned (partial trailing record dropped).
    public static func decode(_ data: Data) throws(CursorTrackError) -> [CursorSample] {
        let bytes = [UInt8](data)
        guard bytes.count >= headerSize else { throw .truncatedHeader }
        guard Array(bytes[0..<4]) == magic else { throw .badMagic }
        let version: UInt16 = read(bytes, at: 4)
        guard version <= currentVersion, version > 0 else { throw .unsupportedVersion(version) }
        let count: UInt32 = read(bytes, at: countOffset)
        let available = (bytes.count - headerSize) / recordSize
        let total: Int
        if count == unknownCount {
            total = available
        } else {
            guard Int(count) <= available else {
                throw .truncatedRecords(expected: Int(count), available: available)
            }
            total = Int(count)
        }
        var samples: [CursorSample] = []
        samples.reserveCapacity(total)
        for i in 0..<total {
            let base = headerSize + i * recordSize
            let t: UInt64 = read(bytes, at: base)
            let x: UInt32 = read(bytes, at: base + 8)
            let y: UInt32 = read(bytes, at: base + 12)
            let shape: UInt16 = read(bytes, at: base + 16)
            let flags: UInt16 = read(bytes, at: base + 18)
            samples.append(CursorSample(
                time: Double(bitPattern: t),
                x: Float(bitPattern: x),
                y: Float(bitPattern: y),
                shapeIndex: shape,
                flags: CursorSampleFlags(rawValue: flags)
            ))
        }
        return samples
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func read<T: FixedWidthInteger>(_ bytes: [UInt8], at offset: Int) -> T {
        var value: T = 0
        for i in 0..<MemoryLayout<T>.size {
            value |= T(bytes[offset + i]) << (8 * i)
        }
        return value
    }
}
