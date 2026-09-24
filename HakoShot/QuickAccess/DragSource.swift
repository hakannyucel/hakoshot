import AppKit
import Foundation
import HakoKit
import os

/// Drag a Quick Access card into Finder / Slack / Mail (plan §4.12): the card's PNG is
/// written to `~/Library/Caches/HakoShot/Drag/<name>.png` and the pasteboard carries
/// that file URL, which every target accepts as a file attachment.
final class DragSource: NSObject, NSDraggingSource {
    private static let log = Logger(subsystem: "com.hakanyucel.HakoShot", category: "quick-access")

    private let onEnd: (_ dropped: Bool) -> Void

    private init(onEnd: @escaping (Bool) -> Void) {
        self.onEnd = onEnd
    }

    /// Starts a dragging session from `view` using `event` (a mouse down/dragged event).
    /// Returns the source, which the caller must keep alive until `onEnd` fires.
    static func begin(
        from view: NSView,
        event: NSEvent,
        fileURL: URL,
        preview: NSImage,
        previewFrame: NSRect,
        onEnd: @escaping (_ dropped: Bool) -> Void
    ) -> DragSource {
        let source = DragSource(onEnd: onEnd)
        let item = NSDraggingItem(pasteboardWriter: fileURL as NSURL)
        item.setDraggingFrame(previewFrame, contents: preview)
        let session = view.beginDraggingSession(with: [item], event: event, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .none
        return source
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        Self.log.debug("drag ended, operation \(operation.rawValue)")
        onEnd(!operation.isEmpty)
    }

    // MARK: Drag files

    /// `~/Library/Caches/HakoShot/Drag/`.
    nonisolated static var dragDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appending(path: "HakoShot/Drag", directoryHint: .isDirectory)
    }

    /// Writes `result` as PNG into its own subfolder of `directory` (so the dropped file
    /// keeps the plain template name, e.g. "HakoShot 2026-09-23 at 14.05.12.png").
    nonisolated static func writeDragFile(
        for result: CaptureResult,
        template: FileNameTemplate,
        modeToken: String,
        counter: Int = 1,
        in directory: URL = dragDirectory
    ) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let date = result.date
        let namer = FileNamer(template: template, pathExtension: ImageFormat.png.fileExtension, clock: { date })
        let url = folder.appending(path: namer.fileName(counter: counter, mode: modeToken))
        let data = try ImageEncoder.encode(
            result.image,
            format: .png,
            options: .defaults(for: .png, scale: result.scale)
        )
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Deletes drag files older than `maxAge` (dropped files may still be read by the
    /// target app for a while, so they are not removed right after the drop).
    nonisolated static func purgeOldDragFiles(olderThan maxAge: TimeInterval = 24 * 3600, in directory: URL = dragDirectory) {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date(timeIntervalSinceNow: -maxAge)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: entry)
            }
        }
    }
}
