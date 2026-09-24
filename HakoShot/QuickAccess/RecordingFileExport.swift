import Foundation
import HakoKit

/// File operations for video / GIF Quick Access cards (kayit-teknik-plan §4.15): the
/// recording already exists on disk (history copy or temp file), so Save, Save As and
/// drag copy that file under a template name instead of encoding pixels.
nonisolated enum RecordingFileExport {
    /// `FileNamer` for `recording`: the user's template, the recording's date and
    /// `.mp4` / `.gif`.
    static func namer(for recording: RecordingResult, template: FileNameTemplate) -> FileNamer {
        let date = recording.date
        return FileNamer(template: template, pathExtension: recording.format.pathExtension, clock: { date })
    }

    /// Suggested file name, e.g. "HakoShot 2026-09-24 at 14.05.12.mp4".
    static func fileName(for recording: RecordingResult, template: FileNameTemplate, counter: Int = 1) -> String {
        namer(for: recording, template: template)
            .fileName(counter: counter, mode: recording.targetKind.fileNameToken)
    }

    /// Non-colliding destination in `folder` (" (2)", " (3)", …).
    static func destinationURL(
        for recording: RecordingResult,
        in folder: URL,
        template: FileNameTemplate,
        counter: Int = 1,
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL {
        namer(for: recording, template: template)
            .resolvedURL(in: folder, counter: counter, mode: recording.targetKind.fileNameToken, fileExists: fileExists)
    }

    /// Copies `recording.fileURL` to a new file in `folder` (created if missing) and
    /// returns it. Never overwrites. APFS clones the file, so this is cheap on the same
    /// volume.
    static func copy(
        _ recording: RecordingResult,
        toFolder folder: URL,
        template: FileNameTemplate,
        counter: Int = 1,
        fileManager: FileManager = .default
    ) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = destinationURL(for: recording, in: folder, template: template, counter: counter) {
            fileManager.fileExists(atPath: $0.path)
        }
        try fileManager.copyItem(at: recording.fileURL, to: destination)
        return destination
    }

    /// Save As: copies to exactly `destination`, replacing a file the save panel
    /// already confirmed overwriting.
    static func copy(_ recording: RecordingResult, replacing destination: URL, fileManager: FileManager = .default) throws {
        let source = recording.fileURL.standardizedFileURL
        let target = destination.standardizedFileURL
        guard source != target else { return }
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: try temporaryCopy(of: source, near: target, fileManager: fileManager))
        } else {
            try fileManager.copyItem(at: source, to: target)
        }
    }

    /// Drag / copy file: a template-named hard link (fallback: copy) to the recording
    /// in its own subfolder of `directory`, so the dropped file has a readable name
    /// instead of the history copy's id.
    static func writeDragFile(
        for recording: RecordingResult,
        template: FileNameTemplate,
        counter: Int = 1,
        in directory: URL = DragSource.dragDirectory,
        fileManager: FileManager = .default
    ) throws -> URL {
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName(for: recording, template: template, counter: counter))
        do {
            try fileManager.linkItem(at: recording.fileURL, to: url)
        } catch {
            try fileManager.copyItem(at: recording.fileURL, to: url)
        }
        return url
    }

    private static func temporaryCopy(of source: URL, near target: URL, fileManager: FileManager) throws -> URL {
        let scratch = try fileManager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        )
        let copy = scratch.appending(path: target.lastPathComponent)
        try fileManager.copyItem(at: source, to: copy)
        return copy
    }
}
