import os

/// Central `os.Logger` instances. Subsystem is the bundle id so
/// `log show --predicate 'subsystem == "com.hakanyucel.HakoShot"'` finds everything.
/// Add a new category here when a feature needs its own log stream.
nonisolated enum Log {
    static let subsystem = "com.hakanyucel.HakoShot"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let coordinator = Logger(subsystem: subsystem, category: "coordinator")
    static let menu = Logger(subsystem: subsystem, category: "menu")
    static let urlScheme = Logger(subsystem: subsystem, category: "url-scheme")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let settings = Logger(subsystem: subsystem, category: "settings")
    static let shortcuts = Logger(subsystem: subsystem, category: "shortcuts")
    static let postCapture = Logger(subsystem: subsystem, category: "post-capture")
}
