import CoreGraphics
import Foundation

/// What a Quick Access card shows (kayit-teknik-plan §4.15): a screenshot or a
/// finished screen recording (mp4 / GIF).
nonisolated enum QuickAccessItem: Sendable {
    case image(CaptureResult)
    case video(RecordingResult)

    /// The screenshot, if this is an image card.
    var capture: CaptureResult? {
        if case .image(let result) = self { return result }
        return nil
    }

    /// The recording, if this is a video / GIF card.
    var recording: RecordingResult? {
        if case .video(let result) = self { return result }
        return nil
    }

    var isVideo: Bool { recording != nil }

    /// Size used for the card's aspect ratio (points for images, pixels for videos:
    /// only the ratio matters).
    var contentSize: CGSize {
        switch self {
        case .image(let result): result.pointSize
        case .video(let result): result.pixelSize
        }
    }

    var date: Date {
        switch self {
        case .image(let result): result.date
        case .video(let result): result.date
        }
    }

    /// `%mode` file-name token.
    @MainActor var fileNameModeToken: String {
        switch self {
        case .image(let result): result.mode.fileNameToken
        case .video(let result): result.targetKind.fileNameToken
        }
    }
}

extension RecordingTargetKind {
    /// `%mode` file-name token for recordings (same words as screenshots).
    nonisolated var fileNameToken: String {
        switch self {
        case .area: "area"
        case .window: "window"
        case .fullscreen, .pickDisplay: "fullscreen"
        }
    }
}

/// Which hover / context-menu controls a card offers (plan §4.15). Pure, so tests can
/// check that video cards hide Pin and Annotate and only show GIF / Edit once their
/// R3 handlers exist.
nonisolated struct QuickAccessCardControls: Equatable, Sendable {
    /// Pin to screen (images only).
    var pin: Bool
    /// Annotate in the screenshot editor (images only).
    var annotate: Bool
    /// Open the video editor (videos, once `onEditRecording` is set).
    var editVideo: Bool
    /// Convert to GIF (mp4 videos, once `onConvertToGIF` is set).
    var convertToGIF: Bool
    /// Open in Studio (mp4 videos, once `onOpenInStudio` is set).
    var openInStudio: Bool
    /// Duration badge with a ▶︎ / "GIF" marker (videos).
    var durationBadge: Bool

    init(item: QuickAccessItem, canEditVideo: Bool = false, canConvertToGIF: Bool = false, canOpenInStudio: Bool = false) {
        switch item {
        case .image:
            pin = true
            annotate = true
            editVideo = false
            convertToGIF = false
            openInStudio = false
            durationBadge = false
        case .video(let recording):
            pin = false
            annotate = false
            editVideo = canEditVideo
            convertToGIF = canConvertToGIF && recording.format == .video
            openInStudio = canOpenInStudio && recording.format == .video
            durationBadge = true
        }
    }
}

/// `m:ss` below one hour, `h:mm:ss` from one hour (plan §4.4 / §4.15). A finished
/// clip rounds to the nearest second (2.97 s → "0:03"); negative / NaN → "0:00".
nonisolated enum QuickAccessDurationFormat {
    static func string(seconds: Double) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded())) : 0
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        func two(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return hours > 0 ? "\(hours):\(two(minutes)):\(two(secs))" : "\(minutes):\(two(secs))"
    }
}
