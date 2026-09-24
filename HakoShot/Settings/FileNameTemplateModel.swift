import Foundation
import HakoKit

/// One `FileNameTemplate` token as the chip editor shows it (plan §5.4 token
/// set `%Y %y %m %B %d %H %h %M %S %p %n %mode`).
nonisolated enum FileNameToken: String, CaseIterable, Sendable, Hashable {
    case year4 = "%Y"
    case year2 = "%y"
    case month = "%m"
    case monthName = "%B"
    case day = "%d"
    case hour24 = "%H"
    case hour12 = "%h"
    case minute = "%M"
    case second = "%S"
    case amPM = "%p"
    case counter = "%n"
    case mode = "%mode"

    /// Chip label.
    var title: String {
        switch self {
        case .year4: "Year"
        case .year2: "Year (26)"
        case .month: "Month"
        case .monthName: "Month Name"
        case .day: "Day"
        case .hour24: "Hour"
        case .hour12: "Hour (12h)"
        case .minute: "Minute"
        case .second: "Second"
        case .amPM: "AM/PM"
        case .counter: "Number"
        case .mode: "Capture Mode"
        }
    }

    /// Palette groups in the chip editor.
    static let dateTokens: [FileNameToken] = [.year4, .year2, .month, .monthName, .day]
    static let timeTokens: [FileNameToken] = [.hour24, .hour12, .minute, .second, .amPM]
    static let otherTokens: [FileNameToken] = [.counter, .mode]
}

/// A piece of a file name pattern: a token chip or literal text.
nonisolated enum FileNameSegment: Hashable, Sendable {
    case token(FileNameToken)
    case text(String)
}

/// Pattern ⇄ chip segments. Parsing mirrors `FileNameTemplate.render`:
/// `%mode` wins over `%m`; an unknown `%x` stays literal text.
nonisolated enum FileNamePatternParser {
    /// Longest raw values first so `%mode` is matched before `%m`.
    private static let tokensByLength = FileNameToken.allCases.sorted { $0.rawValue.count > $1.rawValue.count }

    static func segments(from pattern: String) -> [FileNameSegment] {
        var result: [FileNameSegment] = []
        var text = ""
        var rest = Substring(pattern)
        while let first = rest.first {
            if first == "%", let token = tokensByLength.first(where: { rest.hasPrefix($0.rawValue) }) {
                if !text.isEmpty {
                    result.append(.text(text))
                    text = ""
                }
                result.append(.token(token))
                rest = rest.dropFirst(token.rawValue.count)
            } else {
                text.append(first)
                rest = rest.dropFirst()
            }
        }
        if !text.isEmpty { result.append(.text(text)) }
        return result
    }

    static func pattern(from segments: [FileNameSegment]) -> String {
        segments.map { segment in
            switch segment {
            case let .token(token): token.rawValue
            case let .text(text): text
            }
        }
        .joined()
    }

    /// Adjacent text segments merged, empty ones dropped (after chip edits).
    static func normalized(_ segments: [FileNameSegment]) -> [FileNameSegment] {
        var result: [FileNameSegment] = []
        for segment in segments {
            switch segment {
            case let .text(text):
                guard !text.isEmpty else { continue }
                if case let .text(previous) = result.last {
                    result[result.count - 1] = .text(previous + text)
                } else {
                    result.append(segment)
                }
            case .token:
                result.append(segment)
            }
        }
        return result
    }

    static func usesCounter(_ pattern: String) -> Bool {
        segments(from: pattern).contains(.token(.counter))
    }

    /// Moves the segment at `source` to sit before the segment now at
    /// `destination` (`destination == segments.count` = end).
    static func moving(_ segments: [FileNameSegment], from source: Int, to destination: Int) -> [FileNameSegment] {
        guard segments.indices.contains(source), (0...segments.count).contains(destination) else { return segments }
        var copy = segments
        let item = copy.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        copy.insert(item, at: min(max(target, 0), copy.count))
        return copy
    }
}

extension SettingsKey where Value == Int {
    /// The next `%n` value (Settings > Advanced > File name "Next number").
    /// Default 1. Advanced by `FileNameCounter.take` on each saved file.
    static var outputFileNameCounter: SettingsKey<Int> {
        SettingsKey("outputFileNameCounter", default: 1)
    }
}

/// Running `%n` counter for file names.
enum FileNameCounter {
    /// The value to render `%n` with for the next saved file. Advances the
    /// stored counter only when `pattern` actually contains `%n`.
    static func take(pattern: String, settings: AppSettings) -> Int {
        let value = max(0, settings.value(for: .outputFileNameCounter))
        if FileNamePatternParser.usesCounter(pattern) {
            settings.set(value + 1, for: .outputFileNameCounter)
        }
        return value
    }

    /// Preview only; never advances.
    static func peek(settings: AppSettings) -> Int {
        max(0, settings.value(for: .outputFileNameCounter))
    }
}
