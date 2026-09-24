import Foundation

/// Everything `FileNameTemplate.render(context:)` needs to fill in a pattern's
/// tokens. `date`/`timeZone`/`locale` are all injectable so naming is
/// deterministic in tests (plan §8.1: "sabit tarih + saat dilimi").
public struct FileNameContext: Sendable, Equatable {
    public var date: Date
    public var timeZone: TimeZone
    public var locale: Locale
    /// Value substituted for `%n` — a caller-supplied running capture counter,
    /// distinct from the " (2)" collision suffix `FileNamer` adds separately.
    public var counter: Int
    /// Value substituted for `%mode` (e.g. "area", "window", "scrolling").
    public var mode: String

    public init(
        date: Date,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        counter: Int = 1,
        mode: String = ""
    ) {
        self.date = date
        self.timeZone = timeZone
        self.locale = locale
        self.counter = counter
        self.mode = mode
    }
}

/// A file name pattern using the token set from plan §5.4:
/// `%Y %y %m %B %d %H %h %M %S %p %n %mode`.
///
/// Default: `HakoShot %Y-%m-%d at %H.%M.%S` → `HakoShot 2026-09-23 at 19.10.05`.
public struct FileNameTemplate: Sendable, Equatable {
    public var pattern: String

    public init(pattern: String) {
        self.pattern = pattern
    }

    public static let `default` = FileNameTemplate(pattern: "HakoShot %Y-%m-%d at %H.%M.%S")

    /// Token → replacement order matters: `%mode` must be resolved before
    /// `%m` (year-month), since `%mode` starts with the `%m` token and a
    /// naive pass would otherwise mangle it.
    public func render(context: FileNameContext) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = context.timeZone
        calendar.locale = context.locale

        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: context.date)
        let year = comps.year ?? 0
        let month = comps.month ?? 1
        let day = comps.day ?? 1
        let hour24 = comps.hour ?? 0
        let minute = comps.minute ?? 0
        let second = comps.second ?? 0

        let hour12Raw = hour24 % 12
        let hour12 = hour12Raw == 0 ? 12 : hour12Raw
        let isPM = hour24 >= 12

        let monthSymbols = calendar.monthSymbols
        let monthName = (month >= 1 && month <= monthSymbols.count) ? monthSymbols[month - 1] : ""

        func pad2(_ value: Int) -> String {
            String(format: "%02d", value)
        }

        let replacements: [(token: String, value: String)] = [
            ("%mode", context.mode),
            ("%Y", String(format: "%04d", year)),
            ("%y", pad2(year % 100)),
            ("%m", pad2(month)),
            ("%B", monthName),
            ("%d", pad2(day)),
            ("%H", pad2(hour24)),
            ("%h", pad2(hour12)),
            ("%M", pad2(minute)),
            ("%S", pad2(second)),
            ("%p", isPM ? "PM" : "AM"),
            ("%n", String(context.counter)),
        ]

        var result = pattern
        for replacement in replacements {
            result = result.replacingOccurrences(of: replacement.token, with: replacement.value)
        }
        return result
    }
}
