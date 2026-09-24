import CoreGraphics
import Foundation

/// Identifier of an immutable image asset stored in the project bundle
/// (`assets/<rawValue>.png`, plan §4.9). Documents reference pixels only by ID,
/// never embed them, so undo snapshots stay cheap.
public struct AssetID: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// A fresh ID (uppercase UUID string).
    public init() {
        self.rawValue = UUID().uuidString
    }

    /// Path of the asset inside the `.hakoshot` bundle.
    public var bundlePath: String { "assets/\(rawValue).png" }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// Canvas size in pixels plus the capture's backing scale (points → pixels).
public struct CanvasInfo: Codable, Sendable, Hashable {
    public var width: Int
    public var height: Int
    /// Backing scale of the source capture (2 on Retina). Converts point-based
    /// presets (stroke widths, text sizes, padding) into pixels.
    public var scale: Double

    public init(width: Int, height: Int, scale: Double) {
        self.width = width
        self.height = height
        self.scale = scale
    }

    public var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
}

/// A base image placed on the canvas. A plain capture has exactly one layer
/// covering the canvas; canvas expansion / combine (M5) may move or add layers.
public struct ImageLayer: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var assetID: AssetID
    /// Placement in canvas pixels.
    public var frame: CGRect

    public init(id: UUID = UUID(), assetID: AssetID, frame: CGRect) {
        self.id = id
        self.assetID = assetID
        self.frame = frame
    }
}

/// Whole-canvas rotate / flip (M5). Applied at render time, after crop.
public struct CanvasTransform: Codable, Sendable, Hashable {
    /// Clockwise quarter turns, `0...3`.
    public var rotationQuarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(rotationQuarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.rotationQuarterTurns = ((rotationQuarterTurns % 4) + 4) % 4
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }

    public static let identity = CanvasTransform()
    public var isIdentity: Bool { self == .identity }
}

/// Where the image came from (informational; History/metadata).
public struct CaptureSourceInfo: Codable, Sendable, Hashable {
    /// Capture mode raw value (e.g. "area", "window", "scrolling"), or "file" /
    /// "clipboard" for images opened in the editor.
    public var mode: String
    public var capturedAt: Date?
    public var displayScale: Double?

    public init(mode: String, capturedAt: Date? = nil, displayScale: Double? = nil) {
        self.mode = mode
        self.capturedAt = capturedAt
        self.displayScale = displayScale
    }
}

/// Arbitrary JSON. Was the opaque background slot before `BackgroundStyle`
/// (WP4.1 → WP5.2); kept for raw-JSON handling (e.g. migrations).
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let value = try? c.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? c.decode(Double.self) {
            self = .number(value)
        } else if let value = try? c.decode(String.self) {
            self = .string(value)
        } else if let value = try? c.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try c.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public enum ProjectDocumentError: Error, Sendable, Equatable {
    /// The file was written by a newer HakoShot (`formatVersion` > current).
    case unsupportedFormatVersion(Int)
}

/// The editable document behind the editor and the `.hakoshot` bundle's
/// `project.json` (plan §4.9). A value type: undo snapshots are copies.
///
/// Coordinates: everything (layers, crop, annotations) is in **canvas pixel**
/// space, top-left origin. Crop, transform and background are
/// non-destructive and applied at render time.
///
/// Render order (spec for `DocumentRenderer`, WP4.2):
/// 1. background (if any, M5) around the visible area,
/// 2. image content: `layers` in order, then `.image` annotations in z-order,
/// 3. `.redaction` annotations (in z-order), sampling only pass 2's pixels,
/// 4. every other annotation in z-order (array order),
/// 5. one combined dim layer for all `.spotlight` annotations,
/// then crop to `crop ?? canvas.rect`, then apply `transform`.
public struct ProjectDocument: Sendable, Hashable {
    /// Schema version of `project.json`. Bump + add a migration (WP5.3
    /// `Migration.swift`) on any breaking change.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var createdAt: Date
    public var canvas: CanvasInfo
    public var layers: [ImageLayer]
    /// Crop rect in canvas pixels; `nil` = uncropped.
    public var crop: CGRect?
    public var transform: CanvasTransform
    /// Z-ordered, index 0 at the bottom.
    public var annotations: [Annotation]
    /// Background tool settings; `nil` = no background ("None").
    public var background: BackgroundStyle?
    public var source: CaptureSourceInfo?

    public init(
        canvas: CanvasInfo,
        layers: [ImageLayer],
        annotations: [Annotation] = [],
        crop: CGRect? = nil,
        transform: CanvasTransform = .identity,
        background: BackgroundStyle? = nil,
        source: CaptureSourceInfo? = nil,
        createdAt: Date = Date()
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.createdAt = createdAt
        self.canvas = canvas
        self.layers = layers
        self.crop = crop
        self.transform = transform
        self.annotations = annotations
        self.background = background
        self.source = source
    }

    /// A document for a single image of `pixelWidth × pixelHeight`.
    public init(
        baseImage assetID: AssetID,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        source: CaptureSourceInfo? = nil,
        createdAt: Date = Date()
    ) {
        let canvas = CanvasInfo(width: pixelWidth, height: pixelHeight, scale: scale)
        self.init(
            canvas: canvas,
            layers: [ImageLayer(assetID: assetID, frame: canvas.rect)],
            source: source,
            createdAt: createdAt
        )
    }

    // MARK: Queries

    /// The part of the canvas that gets exported.
    public var visibleRect: CGRect { crop ?? canvas.rect }

    /// Every asset the document references (layers + image annotations +
    /// the background's image fill).
    public var referencedAssets: Set<AssetID> {
        var ids = Set(layers.map(\.assetID))
        for annotation in annotations {
            if case .image(let s) = annotation.kind { ids.insert(s.assetID) }
        }
        if case .image(let id)? = background?.fill { ids.insert(id) }
        return ids
    }

    public func index(of id: Annotation.ID) -> Int? {
        annotations.firstIndex { $0.id == id }
    }

    public func annotation(withID id: Annotation.ID) -> Annotation? {
        annotations.first { $0.id == id }
    }

    /// Number for the next counter: one past the highest existing counter, or
    /// `start` if there are none. Deleting a counter never renumbers the others
    /// (plan §4.10); use `EditorAction.renumberCounters` to close gaps.
    public func nextCounterNumber(start: Int) -> Int {
        let numbers = annotations.compactMap { $0.counter?.number }
        guard let highest = numbers.max() else { return start }
        return highest + 1
    }

    // MARK: JSON

    /// Encoder configured for `project.json` (ISO-8601 dates, sorted keys).
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func jsonData() throws -> Data {
        try Self.makeEncoder().encode(self)
    }

    public init(jsonData: Data) throws {
        self = try Self.makeDecoder().decode(ProjectDocument.self, from: jsonData)
    }
}

extension ProjectDocument: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, createdAt, canvas, layers, crop, transform, annotations, background, source
    }

    /// Unknown keys are ignored; optional sections may be missing. Files from a
    /// newer format version are rejected (older ones go through WP5.3's
    /// migration before reaching this initializer).
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decode(Int.self, forKey: .formatVersion)
        guard version <= Self.currentFormatVersion else {
            throw ProjectDocumentError.unsupportedFormatVersion(version)
        }
        formatVersion = version
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        canvas = try c.decode(CanvasInfo.self, forKey: .canvas)
        layers = try c.decode([ImageLayer].self, forKey: .layers)
        crop = try c.decodeIfPresent(CGRect.self, forKey: .crop)
        transform = try c.decodeIfPresent(CanvasTransform.self, forKey: .transform) ?? .identity
        annotations = try c.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
        // A background that doesn't parse (e.g. the placeholder JSON written
        // before WP5.2) is dropped rather than failing the whole document.
        background = try? c.decodeIfPresent(BackgroundStyle.self, forKey: .background)
        source = try c.decodeIfPresent(CaptureSourceInfo.self, forKey: .source)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(crop, forKey: .crop)
        try c.encode(transform, forKey: .transform)
        try c.encode(annotations, forKey: .annotations)
        try c.encodeIfPresent(background, forKey: .background)
        try c.encodeIfPresent(source, forKey: .source)
    }
}
