import AppKit
import SwiftUI

// The Record button's format dropdown in the pre-record HUD
// (kayit-teknik-plan §4.2, R1.1; CleanShot `recording/format.png`):
// Record Video ↵ / Record GIF ⌥↵ / Record in Studio Mode ⇧↵.

/// What the Record button / Return starts: output format + recording profile.
nonisolated enum RecordFormatChoice: String, CaseIterable, Sendable, Equatable {
    case video
    case gif
    case studio

    /// Menu order (plan §4.2).
    static let menuOrder: [RecordFormatChoice] = [.video, .gif, .studio]

    var format: RecordingFormat {
        switch self {
        case .video, .studio: .video
        case .gif: .gif
        }
    }

    var profile: RecordingProfile {
        switch self {
        case .video, .gif: .classic
        case .studio: .studio
        }
    }

    var title: String {
        switch self {
        case .video: "Record Video"
        case .gif: "Record GIF"
        case .studio: "Record in Studio Mode"
        }
    }

    /// Key hint shown in the menu.
    var shortcutGlyph: String {
        switch self {
        case .video: "↵"
        case .gif: "⌥↵"
        case .studio: "⇧↵"
        }
    }

    /// Return / Enter / double-click with `modifiers`: ⇧ → Studio, else
    /// ⌥ → GIF, else Video (⌘ / ⌃ are ignored).
    static func forConfirm(modifiers: NSEvent.ModifierFlags) -> RecordFormatChoice {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.shift) { return .studio }
        if flags.contains(.option) { return .gif }
        return .video
    }

    /// Per-recording changes on top of the user's settings.
    var overrides: RecordingOptionsOverrides {
        switch self {
        case .video, .gif: RecordingOptionsOverrides()
        // Plan §5.2 "Studio ham kalite": Ultra, no cursor (it is metadata).
        case .studio: RecordingOptionsOverrides(showsCursor: false, quality: .ultra)
        }
    }
}

/// Changes one recording makes to `RecordingOptions(settings:)`; `nil` = keep.
nonisolated struct RecordingOptionsOverrides: Sendable, Equatable {
    var showsCursor: Bool?
    var quality: RecordingQuality?

    init(showsCursor: Bool? = nil, quality: RecordingQuality? = nil) {
        self.showsCursor = showsCursor
        self.quality = quality
    }

    var isEmpty: Bool { self == RecordingOptionsOverrides() }

    func applied(to options: RecordingOptions) -> RecordingOptions {
        var options = options
        if let showsCursor { options.showsCursor = showsCursor }
        if let quality { options.quality = quality }
        return options
    }
}

/// The result the HUD hands to the coordinator (R1.I).
nonisolated struct RecordingHUDSelection: Sendable, Equatable {
    var choice: RecordFormatChoice
    var format: RecordingFormat { choice.format }
    var profile: RecordingProfile { choice.profile }
    var overrides: RecordingOptionsOverrides { choice.overrides }

    /// Settings (HUD toggles included) + this choice's overrides.
    @MainActor
    func options(settings: AppSettings) -> RecordingOptions {
        overrides.applied(to: RecordingOptions(settings: settings))
    }
}

// MARK: - View

/// The dropdown: one row per `RecordFormatChoice` with its key hint.
struct RecordFormatMenu: View {
    let onSelect: (RecordFormatChoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(RecordFormatChoice.menuOrder, id: \.self) { choice in
                HUDMenuRow(title: choice.title, showsCheckColumn: false, trailing: choice.shortcutGlyph) {
                    RecordFormatIcon(choice: choice)
                } action: {
                    onSelect(choice)
                }
            }
        }
        .padding(Tokens.Recording.hudMenuPadding)
        .frame(width: Tokens.Recording.hudFormatMenuWidth)
        .hudPanel(cornerRadius: Tokens.AllInOne.menuRadius, shadow: .toast)
    }
}

/// Video camera, a "GIF" badge, or a clapperboard (CleanShot's menu icons).
struct RecordFormatIcon: View {
    let choice: RecordFormatChoice

    var body: some View {
        Group {
            switch choice {
            case .video:
                Image(systemName: "video.fill")
                    .font(.system(size: Tokens.Recording.hudMenuIconSize, weight: .medium))
            case .gif:
                Text("GIF")
                    .font(Tokens.Recording.hudGIFBadgeFont)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextOnLight))
                    .padding(.horizontal, Tokens.Recording.hudGIFBadgePaddingH)
                    .background {
                        RoundedRectangle(cornerRadius: Tokens.Recording.hudGIFBadgeRadius, style: .continuous)
                            .fill(Color(nsColor: Tokens.Palette.hudLightFill))
                    }
            case .studio:
                Image(systemName: "movieclapper")
                    .font(.system(size: Tokens.Recording.hudMenuIconSize, weight: .medium))
            }
        }
        .frame(width: Tokens.Recording.hudMenuIconWidth)
    }
}
