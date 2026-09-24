import CoreGraphics
import Foundation

/// The mode buttons of the All-In-One bar (plan §4.14, UI report §3; no
/// Recording: HakoShot is screenshots only).
nonisolated enum AllInOneMode: String, CaseIterable, Sendable {
    case area, fullscreen, window, scrolling, timer, text

    var title: String {
        switch self {
        case .area: "Area"
        case .fullscreen: "Fullscreen"
        case .window: "Window"
        case .scrolling: "Scrolling"
        case .timer: "Timer"
        case .text: "Text"
        }
    }

    var symbol: String {
        switch self {
        case .area: "viewfinder"
        case .fullscreen: "display"
        case .window: "macwindow"
        case .scrolling: "arrow.down.to.line.compact"
        case .timer: "timer"
        case .text: "textformat"
        }
    }

    /// Every mode works (Scrolling since M6); kept for modes that may be gated later.
    var isAvailable: Bool { true }

    /// Modes that run on the area selection.
    var usesSelection: Bool {
        switch self {
        case .area, .scrolling, .timer, .text: true
        case .fullscreen, .window: false
        }
    }
}

/// Aspect-ratio menu of the size bar (plan §4.14).
nonisolated enum AspectRatioPreset: Hashable, Sendable {
    case freeform
    case fixed(width: Int, height: Int)
    /// Locks whatever ratio the selection has right now.
    case custom(CGFloat)

    static let menu: [AspectRatioPreset] = [
        .freeform,
        .fixed(width: 1, height: 1),
        .fixed(width: 4, height: 3),
        .fixed(width: 3, height: 2),
        .fixed(width: 16, height: 9),
        .fixed(width: 16, height: 10),
        .fixed(width: 9, height: 16),
    ]

    /// width / height; `nil` = freeform.
    var ratio: CGFloat? {
        switch self {
        case .freeform: nil
        case .fixed(let width, let height): CGFloat(width) / CGFloat(height)
        case .custom(let ratio): ratio
        }
    }

    var title: String {
        switch self {
        case .freeform: "Freeform"
        case .fixed(let width, let height): "\(width):\(height)"
        case .custom: "Custom"
        }
    }

    var isLocked: Bool { ratio != nil }

    /// The other side for a typed width or height under this ratio.
    static func size(width: CGFloat? = nil, height: CGFloat? = nil, current: CGSize, ratio: CGFloat?) -> CGSize {
        let w = width ?? current.width
        let h = height ?? current.height
        guard let ratio, ratio > 0 else { return CGSize(width: w, height: h) }
        if width != nil { return CGSize(width: w, height: (w / ratio).rounded()) }
        if height != nil { return CGSize(width: (h * ratio).rounded(), height: h) }
        return CGSize(width: w, height: h)
    }
}

/// State of the All-In-One bar (SwiftUI observes it; `AllInOneBar` drives it).
@Observable
final class AllInOneModel {
    /// Highlighted mode; `Return` / the capture button run it (default Area).
    var activeMode: AllInOneMode = .area
    /// Selection size in points; `nil` without a selection.
    var selectionSize: CGSize?
    var isWindowMode = false
    var ratio: AspectRatioPreset = .freeform
    var showsRatioMenu = false
    var widthText = ""
    var heightText = ""
    /// A size field has focus: don't overwrite what the user is typing.
    var isEditingSize = false

    func updateSizeTexts() {
        guard !isEditingSize else { return }
        widthText = selectionSize.map { "\(Int($0.width.rounded()))" } ?? ""
        heightText = selectionSize.map { "\(Int($0.height.rounded()))" } ?? ""
    }
}
