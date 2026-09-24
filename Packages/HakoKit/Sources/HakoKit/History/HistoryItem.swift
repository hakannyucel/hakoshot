import Foundation

/// How a history entry was captured (plan §4.12). Mirrors the app's
/// `CaptureMode` without its associated values so HakoKit stays independent
/// of the app target. Unknown raw values (e.g. written by a newer build)
/// decode as `.unknown` instead of failing the whole entry.
public enum HistoryCaptureKind: String, Sendable, CaseIterable, Codable, Equatable {
    case area
    case window
    case fullscreen
    case previousArea
    case scrolling
    case selfTimer
    case allInOne
    case text
    /// Classic screen recording, delivered as a video file (kayit-teknik-plan §4.15).
    case recording
    /// Recorded (or converted) straight to GIF.
    case gif
    /// Studio Mode project (`.hakostudio` package).
    case studio
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HistoryCaptureKind(rawValue: raw) ?? .unknown
    }

    /// Whether this entry carries video/GIF/Studio media rather than a still image.
    public var isVideo: Bool {
        switch self {
        case .recording, .gif, .studio: true
        default: false
        }
    }
}

/// History overlay filter pills (plan §5.4: All / Screenshots / Recordings / Scrolling / Text).
public enum HistoryFilter: String, Sendable, CaseIterable, Equatable {
    case all
    case screenshots
    case recordings
    case scrolling
    case text

    public var title: String {
        switch self {
        case .all: "All"
        case .screenshots: "Screenshots"
        case .recordings: "Recordings"
        case .scrolling: "Scrolling"
        case .text: "Text"
        }
    }

    public func matches(_ kind: HistoryCaptureKind) -> Bool {
        switch self {
        case .all: true
        case .scrolling: kind == .scrolling
        case .text: kind == .text
        case .recordings: kind.isVideo
        case .screenshots: kind != .scrolling && kind != .text && !kind.isVideo
        }
    }
}

/// The delivered media's container, for video/GIF/Studio history entries
/// (kayit-teknik-plan §4.15). Independent of `HistoryCaptureKind` so a
/// Studio entry's preview clip can still say what it is.
public enum HistoryMediaFormat: String, Sendable, CaseIterable, Codable, Equatable {
    case video
    case gif

    /// Extension used for `HistoryLayout.mediaFileName(id:date:format:)`.
    public var pathExtension: String {
        switch self {
        case .video: "mp4"
        case .gif: "gif"
        }
    }
}

/// One stored capture in the history index (`history.json`).
///
/// File names are **relative to the history root** (e.g.
/// `2026-09/<uuid>.png`), so the whole folder can move without rewriting the
/// index. Decoding is lenient: missing optional/newer fields fall back to
/// defaults so an older or hand-edited index still loads.
public struct HistoryItem: Sendable, Equatable, Identifiable, Codable {
    public var id: UUID
    public var date: Date
    public var kind: HistoryCaptureKind
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Backing scale of the source display (2 on Retina).
    public var scale: Double
    /// Full-resolution PNG, relative to the history root.
    public var imageFileName: String
    /// Small JPEG thumbnail (≤ 480 px), relative to the history root.
    public var thumbnailFileName: String
    /// Where the capture was saved by the user, if anywhere.
    public var savedFileURL: URL?
    /// Editable `.hakoshot` project, relative to the history root (M5).
    public var projectFileName: String?
    /// The capture's Quick Access card was closed/dismissed; candidates for
    /// "Restore Recently Closed".
    public var isClosed: Bool
    public var closedDate: Date?

    // MARK: Video / GIF / Studio (kayit-teknik-plan §4.15, R0.4). All optional
    // so old `history.json` entries (and plain screenshots) decode unchanged.

    /// The delivered mp4/gif, relative to the history root. `nil` for screenshots.
    public var mediaFileName: String?
    /// Media duration in seconds. `nil` for screenshots.
    public var durationSeconds: Double?
    /// `mediaFileName`'s container. `nil` for screenshots.
    public var mediaFormat: HistoryMediaFormat?
    /// `RecordingMetadata` JSON (`events.json`) copied alongside the media,
    /// relative to the history root. Reserved for a later package (R5/R6:
    /// "Open in Studio" from history); `addRecording` (R0.4) does not set it yet.
    public var eventsFileName: String?
    /// Studio Mode `.hakostudio` package, relative to the history root.
    public var studioPackageName: String?

    public init(
        id: UUID = UUID(),
        date: Date,
        kind: HistoryCaptureKind,
        pixelWidth: Int,
        pixelHeight: Int,
        scale: Double,
        imageFileName: String,
        thumbnailFileName: String,
        savedFileURL: URL? = nil,
        projectFileName: String? = nil,
        isClosed: Bool = false,
        closedDate: Date? = nil,
        mediaFileName: String? = nil,
        durationSeconds: Double? = nil,
        mediaFormat: HistoryMediaFormat? = nil,
        eventsFileName: String? = nil,
        studioPackageName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.kind = kind
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.imageFileName = imageFileName
        self.thumbnailFileName = thumbnailFileName
        self.savedFileURL = savedFileURL
        self.projectFileName = projectFileName
        self.isClosed = isClosed
        self.closedDate = closedDate
        self.mediaFileName = mediaFileName
        self.durationSeconds = durationSeconds
        self.mediaFormat = mediaFormat
        self.eventsFileName = eventsFileName
        self.studioPackageName = studioPackageName
    }

    /// Size in points (`pixels / scale`).
    public var pointWidth: Double { Double(pixelWidth) / max(scale, 1) }
    public var pointHeight: Double { Double(pixelHeight) / max(scale, 1) }

    /// Every file this entry owns, relative to the history root (retention
    /// deletes all of these; `studioPackageName` is a package directory, also
    /// removed fine by a plain `FileManager.removeItem`).
    public var ownedFileNames: [String] {
        [imageFileName, thumbnailFileName]
            + (projectFileName.map { [$0] } ?? [])
            + (mediaFileName.map { [$0] } ?? [])
            + (eventsFileName.map { [$0] } ?? [])
            + (studioPackageName.map { [$0] } ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, kind, pixelWidth, pixelHeight, scale
        case imageFileName, thumbnailFileName, savedFileURL, projectFileName
        case isClosed, closedDate
        case mediaFileName, durationSeconds, mediaFormat, eventsFileName, studioPackageName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        imageFileName = try c.decode(String.self, forKey: .imageFileName)
        kind = (try? c.decodeIfPresent(HistoryCaptureKind.self, forKey: .kind)) ?? .unknown
        pixelWidth = (try? c.decodeIfPresent(Int.self, forKey: .pixelWidth)) ?? 0
        pixelHeight = (try? c.decodeIfPresent(Int.self, forKey: .pixelHeight)) ?? 0
        scale = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? 1
        thumbnailFileName = (try? c.decodeIfPresent(String.self, forKey: .thumbnailFileName))
            ?? HistoryLayout.thumbnailFileName(forImageFileName: imageFileName)
        savedFileURL = try? c.decodeIfPresent(URL.self, forKey: .savedFileURL)
        projectFileName = try? c.decodeIfPresent(String.self, forKey: .projectFileName)
        isClosed = (try? c.decodeIfPresent(Bool.self, forKey: .isClosed)) ?? false
        closedDate = try? c.decodeIfPresent(Date.self, forKey: .closedDate)
        mediaFileName = try? c.decodeIfPresent(String.self, forKey: .mediaFileName)
        durationSeconds = try? c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        mediaFormat = (try? c.decodeIfPresent(HistoryMediaFormat.self, forKey: .mediaFormat)) ?? nil
        eventsFileName = try? c.decodeIfPresent(String.self, forKey: .eventsFileName)
        studioPackageName = try? c.decodeIfPresent(String.self, forKey: .studioPackageName)
    }
}

/// On-disk naming under the history root (plan §4.12):
/// `<yyyy-MM>/<uuid>.png`, `<yyyy-MM>/<uuid>-thumb.jpg`, `<yyyy-MM>/<uuid>.hakoshot`.
public enum HistoryLayout {
    public static let indexFileName = "history.json"
    public static let imageExtension = "png"
    public static let thumbnailSuffix = "-thumb.jpg"
    public static let projectExtension = "hakoshot"
    /// Longest edge of the stored thumbnail, in pixels.
    public static let thumbnailMaxPixelSize = 480

    /// `yyyy-MM` month folder for `date` in `calendar`'s time zone.
    public static func monthFolder(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let year = parts.year ?? 1970
        let month = parts.month ?? 1
        return String(format: "%04d-%02d", year, month)
    }

    public static func imageFileName(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        "\(monthFolder(for: date, calendar: calendar))/\(id.uuidString).\(imageExtension)"
    }

    public static func thumbnailFileName(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        "\(monthFolder(for: date, calendar: calendar))/\(id.uuidString)\(thumbnailSuffix)"
    }

    public static func projectFileName(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        "\(monthFolder(for: date, calendar: calendar))/\(id.uuidString).\(projectExtension)"
    }

    // MARK: Video / GIF / Studio (kayit-teknik-plan §4.15, R0.4)

    public static let eventsSuffix = "-events.json"
    public static let studioPackageExtension = "hakostudio"

    /// `<yyyy-MM>/<uuid>.mp4` or `.gif`, matching `format`.
    public static func mediaFileName(id: UUID, date: Date, format: HistoryMediaFormat, calendar: Calendar = .current) -> String {
        "\(monthFolder(for: date, calendar: calendar))/\(id.uuidString).\(format.pathExtension)"
    }

    /// `<yyyy-MM>/<uuid>-events.json` (copied `RecordingMetadata`, reserved for a later package).
    public static func eventsFileName(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        "\(monthFolder(for: date, calendar: calendar))/\(id.uuidString)\(eventsSuffix)"
    }

    /// `<yyyy-MM>/<uuid>.hakostudio` package.
    public static func studioPackageName(id: UUID, date: Date, calendar: Calendar = .current) -> String {
        "\(monthFolder(for: date, calendar: calendar))/\(id.uuidString).\(studioPackageExtension)"
    }

    /// `2026-09/<uuid>.png` → `2026-09/<uuid>-thumb.jpg`.
    public static func thumbnailFileName(forImageFileName imageFileName: String) -> String {
        let base = (imageFileName as NSString).deletingPathExtension
        return base + thumbnailSuffix
    }

    /// The entry id encoded in an original image's file name, or `nil` for
    /// thumbnails, projects and foreign files.
    public static func id(fromImageFileName fileName: String) -> UUID? {
        let last = (fileName as NSString).lastPathComponent
        guard (last as NSString).pathExtension.lowercased() == imageExtension else { return nil }
        return UUID(uuidString: (last as NSString).deletingPathExtension)
    }
}
