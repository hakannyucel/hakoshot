import CoreGraphics
import Foundation

public enum RecordingMetadataError: Error, Sendable, Equatable {
    /// `events.json` was written by a newer HakoShot.
    case unsupportedFormatVersion(Int)
}

/// Mouse button of a click event.
public enum RecordingMouseButton: String, Sendable, Hashable, Codable {
    case left, right, other
}

/// A mouse button press/release (plan §1.6).
public struct RecordingClickEvent: Sendable, Hashable, Codable {
    /// Media seconds (already mapped through `RecordingTimeline`).
    public var time: Double
    /// Points relative to the recording rect's top-left corner.
    public var x: Double
    public var y: Double
    public var button: RecordingMouseButton
    /// `true` = down, `false` = up.
    public var isDown: Bool
    /// `NSEvent.clickCount` for downs (double-click = 2); 1 otherwise.
    public var clickCount: Int

    public init(time: Double, x: Double, y: Double, button: RecordingMouseButton = .left, isDown: Bool = true, clickCount: Int = 1) {
        self.time = time
        self.x = x
        self.y = y
        self.button = button
        self.isDown = isDown
        self.clickCount = clickCount
    }

    public var point: CGPoint { CGPoint(x: x, y: y) }

    private enum CodingKeys: String, CodingKey { case time, x, y, button, isDown, clickCount }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        button = (try? c.decodeIfPresent(RecordingMouseButton.self, forKey: .button)) ?? .left
        isDown = try c.decodeIfPresent(Bool.self, forKey: .isDown) ?? true
        clickCount = try c.decodeIfPresent(Int.self, forKey: .clickCount) ?? 1
    }
}

/// A key event from the listen-only event tap (plan §1.6, §4.9). Only keys
/// that pass the keystroke filter are stored (privacy).
public struct RecordingKeyEvent: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case keyDown
        case flagsChanged
    }

    /// Media seconds.
    public var time: Double
    public var kind: Kind
    /// Virtual key code (`kVK_*`).
    public var keyCode: UInt16
    /// Raw `CGEventFlags` bits (device-independent modifier mask is enough).
    public var modifierFlags: UInt64
    /// Characters ignoring modifiers, if any (for letters/digits).
    public var characters: String?
    /// Auto-repeat keyDown.
    public var isRepeat: Bool

    public init(time: Double, kind: Kind = .keyDown, keyCode: UInt16, modifierFlags: UInt64 = 0, characters: String? = nil, isRepeat: Bool = false) {
        self.time = time
        self.kind = kind
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.characters = characters
        self.isRepeat = isRepeat
    }

    private enum CodingKeys: String, CodingKey { case time, kind, keyCode, modifierFlags, characters, isRepeat }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        time = try c.decode(Double.self, forKey: .time)
        kind = (try? c.decodeIfPresent(Kind.self, forKey: .kind)) ?? .keyDown
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        modifierFlags = try c.decodeIfPresent(UInt64.self, forKey: .modifierFlags) ?? 0
        characters = try c.decodeIfPresent(String.self, forKey: .characters)
        isRepeat = try c.decodeIfPresent(Bool.self, forKey: .isRepeat) ?? false
    }
}

/// A distinct cursor image. `cursor.bin` samples reference these by array
/// index (`shapeIndex`).
public struct RecordingCursorShape: Sendable, Hashable, Codable {
    /// Content hash of the PNG (dedupe key); the file is `cursors/<hash>.png`.
    public var hash: String
    /// Hot spot in points from the image's top-left.
    public var hotSpotX: Double
    public var hotSpotY: Double
    /// Image size in points.
    public var width: Double
    public var height: Double

    public init(hash: String, hotSpotX: Double, hotSpotY: Double, width: Double, height: Double) {
        self.hash = hash
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.width = width
        self.height = height
    }

    /// Path relative to the session / `media/` folder.
    public var fileName: String { "cursors/\(hash).png" }
}

/// Where and how big the recording was (plan §2.2).
public struct RecordingGeometryInfo: Sendable, Hashable, Codable {
    /// Recorded rect in Quartz global points (top-left origin).
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    /// `CGDirectDisplayID` of the recorded display.
    public var displayID: UInt32
    /// Display backing scale factor at record time.
    public var scale: Double
    /// Encoded frame size.
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(rect: CGRect, displayID: UInt32, scale: Double, pixelWidth: Int, pixelHeight: Int) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.width
        self.height = rect.height
        self.displayID = displayID
        self.scale = scale
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    /// Output pixels per metadata point.
    public var pixelsPerPoint: Double { width > 0 ? Double(pixelWidth) / width : scale }
}

/// `events.json`: everything recorded next to the video (plan §2.2, §4.18).
/// Immutable once the session ends.
///
/// Times: `pauses` and `hostTimeOrigin` are host seconds; every event
/// `time` is media seconds (source time, before trim). Positions are points
/// relative to the recording rect (pixels = points × `geometry.pixelsPerPoint`).
///
/// Decoding: unknown keys are ignored, missing lists default to empty, a
/// newer `formatVersion` is rejected.
public struct RecordingMetadata: Sendable, Hashable {
    public static let currentFormatVersion = 1
    public static let fileName = "events.json"

    public var formatVersion: Int
    /// Host seconds of media time 0 (first screen frame).
    public var hostTimeOrigin: Double
    /// Pause intervals in host seconds.
    public var pauses: [ClosedRange<Double>]
    public var geometry: RecordingGeometryInfo
    public var clicks: [RecordingClickEvent]
    public var keys: [RecordingKeyEvent]
    public var cursorShapes: [RecordingCursorShape]
    /// The cursor is part of the video pixels (classic recordings).
    public var cursorBakedIn: Bool
    /// `camera.mov` time minus screen media time, seconds; `nil` = no camera.
    public var cameraTimeOffset: Double?
    public var droppedFrames: Int

    public init(
        hostTimeOrigin: Double,
        pauses: [ClosedRange<Double>] = [],
        geometry: RecordingGeometryInfo,
        clicks: [RecordingClickEvent] = [],
        keys: [RecordingKeyEvent] = [],
        cursorShapes: [RecordingCursorShape] = [],
        cursorBakedIn: Bool,
        cameraTimeOffset: Double? = nil,
        droppedFrames: Int = 0
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.hostTimeOrigin = hostTimeOrigin
        self.pauses = pauses
        self.geometry = geometry
        self.clicks = clicks
        self.keys = keys
        self.cursorShapes = cursorShapes
        self.cursorBakedIn = cursorBakedIn
        self.cameraTimeOffset = cameraTimeOffset
        self.droppedFrames = droppedFrames
    }

    /// Timeline built from `hostTimeOrigin` + `pauses`.
    public var timeline: RecordingTimeline {
        RecordingTimeline(origin: hostTimeOrigin, pauses: pauses)
    }

    /// Pretty, sorted-keys JSON (stable diffs).
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public init(jsonData: Data) throws {
        self = try JSONDecoder().decode(RecordingMetadata.self, from: jsonData)
    }
}

extension RecordingMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, hostTimeOrigin, pauses, geometry, clicks, keys, cursorShapes,
             cursorBakedIn, cameraTimeOffset, droppedFrames
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Self.currentFormatVersion else {
            throw RecordingMetadataError.unsupportedFormatVersion(version)
        }
        formatVersion = version
        hostTimeOrigin = try c.decodeIfPresent(Double.self, forKey: .hostTimeOrigin) ?? 0
        pauses = try c.decodeIfPresent([ClosedRange<Double>].self, forKey: .pauses) ?? []
        geometry = try c.decode(RecordingGeometryInfo.self, forKey: .geometry)
        clicks = try c.decodeIfPresent([RecordingClickEvent].self, forKey: .clicks) ?? []
        keys = try c.decodeIfPresent([RecordingKeyEvent].self, forKey: .keys) ?? []
        cursorShapes = try c.decodeIfPresent([RecordingCursorShape].self, forKey: .cursorShapes) ?? []
        cursorBakedIn = try c.decodeIfPresent(Bool.self, forKey: .cursorBakedIn) ?? false
        cameraTimeOffset = try c.decodeIfPresent(Double.self, forKey: .cameraTimeOffset)
        droppedFrames = try c.decodeIfPresent(Int.self, forKey: .droppedFrames) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(hostTimeOrigin, forKey: .hostTimeOrigin)
        try c.encode(pauses, forKey: .pauses)
        try c.encode(geometry, forKey: .geometry)
        try c.encode(clicks, forKey: .clicks)
        try c.encode(keys, forKey: .keys)
        try c.encode(cursorShapes, forKey: .cursorShapes)
        try c.encode(cursorBakedIn, forKey: .cursorBakedIn)
        try c.encodeIfPresent(cameraTimeOffset, forKey: .cameraTimeOffset)
        try c.encode(droppedFrames, forKey: .droppedFrames)
    }
}
