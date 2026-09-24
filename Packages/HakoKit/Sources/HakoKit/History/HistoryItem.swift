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
    case unknown

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = HistoryCaptureKind(rawValue: raw) ?? .unknown
    }
}

/// History overlay filter pills (plan §5.4: All / Screenshots / Scrolling / Text).
public enum HistoryFilter: String, Sendable, CaseIterable, Equatable {
    case all
    case screenshots
    case scrolling
    case text

    public var title: String {
        switch self {
        case .all: "All"
        case .screenshots: "Screenshots"
        case .scrolling: "Scrolling"
        case .text: "Text"
        }
    }

    public func matches(_ kind: HistoryCaptureKind) -> Bool {
        switch self {
        case .all: true
        case .scrolling: kind == .scrolling
        case .text: kind == .text
        case .screenshots: kind != .scrolling && kind != .text
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
        closedDate: Date? = nil
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
    }

    /// Size in points (`pixels / scale`).
    public var pointWidth: Double { Double(pixelWidth) / max(scale, 1) }
    public var pointHeight: Double { Double(pixelHeight) / max(scale, 1) }

    /// Every file this entry owns, relative to the history root.
    public var ownedFileNames: [String] {
        [imageFileName, thumbnailFileName] + (projectFileName.map { [$0] } ?? [])
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, kind, pixelWidth, pixelHeight, scale
        case imageFileName, thumbnailFileName, savedFileURL, projectFileName
        case isClosed, closedDate
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
