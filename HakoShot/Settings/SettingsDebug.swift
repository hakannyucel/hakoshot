#if DEBUG
import os
import AppKit

/// `-HakoFileNameEditorSnapshot <png path>`: Advanced opens the file name
/// editor sheet and writes a snapshot of it (visual check while the display sleeps).
enum SettingsDebug {
    static var fileNameEditorSnapshotURL: URL? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-HakoFileNameEditorSnapshot"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    static func snapshotSheet(to url: URL) async {
        try? await Task.sleep(for: .milliseconds(900))
        guard let sheet = NSApp.windows.compactMap(\.attachedSheet).first, let view = sheet.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            Log.settings.error("debug: no sheet to snapshot")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        Log.settings.notice("debug: file name editor snapshot -> \(url.path, privacy: .public)")
    }
}
#endif
