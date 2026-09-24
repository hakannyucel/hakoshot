import Foundation

/// Renders template-based file names and resolves collisions by appending
/// " (2)", " (3)", … (plan §5.4). `clock`/`timeZone`/`locale` are injectable
/// so tests are deterministic; `fileExists` on `resolvedURL` is injectable so
/// collision resolution doesn't touch the real file system in tests.
public struct FileNamer: Sendable {
    public var template: FileNameTemplate
    /// File extension appended after the rendered name, without a dot (e.g. "png").
    public var pathExtension: String
    public var timeZone: TimeZone
    public var locale: Locale
    public var clock: @Sendable () -> Date
    /// Appended directly after the rendered, sanitized template — before any
    /// " (2)", " (3)", … collision suffix `resolvedURL` adds — e.g. `"@2x"`
    /// (plan §4.7 "Add @2x suffix to Retina files"). Empty by default.
    public var retinaSuffix: String

    public init(
        template: FileNameTemplate = .default,
        pathExtension: String,
        timeZone: TimeZone = .current,
        locale: Locale = Locale(identifier: "en_US_POSIX"),
        clock: @escaping @Sendable () -> Date = Date.init,
        retinaSuffix: String = ""
    ) {
        self.template = template
        self.pathExtension = pathExtension
        self.timeZone = timeZone
        self.locale = locale
        self.clock = clock
        self.retinaSuffix = retinaSuffix
    }

    /// The rendered, sanitized base name (no extension), including
    /// `retinaSuffix`, for one capture.
    public func baseName(counter: Int = 1, mode: String = "") -> String {
        let context = FileNameContext(
            date: clock(),
            timeZone: timeZone,
            locale: locale,
            counter: counter,
            mode: mode
        )
        return Self.sanitize(template.render(context: context)) + retinaSuffix
    }

    /// The rendered, sanitized file name including extension.
    public func fileName(counter: Int = 1, mode: String = "") -> String {
        "\(baseName(counter: counter, mode: mode)).\(pathExtension)"
    }

    /// Resolves a non-colliding URL inside `directory` for one capture,
    /// appending " (2)", " (3)", … to the base name as needed. `fileExists`
    /// defaults to the real file system but is injectable for tests.
    public func resolvedURL(
        in directory: URL,
        counter: Int = 1,
        mode: String = "",
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        let base = baseName(counter: counter, mode: mode)
        var candidate = directory.appendingPathComponent("\(base).\(pathExtension)")
        var suffix = 2
        while fileExists(candidate) {
            candidate = directory.appendingPathComponent("\(base) (\(suffix)).\(pathExtension)")
            suffix += 1
        }
        return candidate
    }

    /// Replaces characters that are invalid or awkward in a macOS file name
    /// (`/` is a path separator; `:` maps to `/` on HFS+/APFS and confuses
    /// Finder; `\` is disallowed defensively) with `-`.
    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        var result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            result.append(invalid.contains(scalar) ? "-" : scalar)
        }
        return String(result)
    }
}
