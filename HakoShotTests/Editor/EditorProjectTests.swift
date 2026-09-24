import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

@MainActor
@Suite("Editor project files")
struct EditorProjectTests {
    private func makeImage() throws -> CGImage {
        let context = CGContext(
            data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        context?.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        context?.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        return try #require(context?.makeImage())
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "EditorProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func saveAsProjectRoundTripsEditableAnnotations() throws {
        let folder = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = EditorViewModel(image: try makeImage(), scale: 2, mode: .window)
        let rect = Annotation(kind: .rectangle(RectShape(rect: CGRect(x: 10, y: 10, width: 100, height: 50))), style: AnnotationStyle())
        model.perform(.add(rect))

        let url = folder.appending(path: "Test.hakoshot")
        #expect(model.save(as: .project, to: url))
        #expect(model.projectURL == url)
        #expect(!model.store.hasUnsavedChanges)
        #expect(FileManager.default.fileExists(atPath: url.appending(path: ProjectFile.projectFileName).path))

        let contents = try ProjectFile.read(from: url)
        let reopened = try #require(EditorViewModel(project: contents, projectURL: url))
        #expect(reopened.document.annotations == model.document.annotations)
        #expect(reopened.captureMode == .window)
        #expect(reopened.baseImage.width == 300)
        #expect(reopened.projectURL == url)

        // ⌘S on a project writes the package again.
        reopened.perform(.selectAll)
        reopened.perform(.deleteSelection)
        #expect(reopened.save())
        #expect(try ProjectFile.read(from: url).document.annotations.isEmpty)
    }

    @Test func saveReportsToHistoryHook() throws {
        let folder = try temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: folder)
            EditorDocumentEvents.onSaved = nil
        }
        let assigned = UUID()
        var events: [EditorSaveEvent] = []
        EditorDocumentEvents.onSaved = { event in
            events.append(event)
            return assigned
        }
        let model = EditorViewModel(image: try makeImage(), scale: 1, mode: .area)
        let png = folder.appending(path: "Shot.png")
        #expect(model.save(as: .image(.png), to: png))
        #expect(events.count == 1)
        #expect(events.first?.imageURL == png)
        #expect(events.first?.historyID == nil)
        #expect(model.historyID == assigned)

        #expect(model.save())
        #expect(events.last?.historyID == assigned)
    }

    @Test func fileNameTokensRoundTrip() {
        let modes: [CaptureMode] = [.area, .window, .fullscreen(.preferred), .previousArea, .scrolling, .selfTimer, .allInOne, .text]
        for mode in modes {
            #expect(CaptureMode(fileNameToken: mode.fileNameToken) == mode)
        }
        #expect(CaptureMode(fileNameToken: "nope") == nil)
    }

    @Test func dpiToScale() {
        #expect(EditorDocumentOpener.scaleForDPI(72) == 1)
        #expect(EditorDocumentOpener.scaleForDPI(144) == 2)
        #expect(EditorDocumentOpener.scaleForDPI(0) == 1)
        #expect(EditorDocumentOpener.scaleForDPI(.nan) == 1)
    }
}
