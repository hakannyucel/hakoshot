import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("StudioProject")
struct StudioProjectTests {
    static func fullProject() -> StudioProject {
        var p = V1StudioFixture.project()
        p.source.media.camera = "camera.mov"
        p.source.audioTracks = ["microphone", "system"]
        p.camera = StudioCameraSettings(visible: false, shape: .vertical, size: 0.25, corner: .topLeft, mirrored: true)
        p.keystrokes = StudioKeystrokeSettings(visible: true, style: "light", position: "topCenter", size: "large")
        p.audio = VideoEditAudio(muted: false, volume: 0.8, mono: true, trackGains: [1, 0.5])
        p.export = StudioExportSettings(format: .gif, fps: 24, quality: .ultra, codec: .hevc,
                                        gif: GIFExportOptions(fps: 10, width: 600, optimize: false, quality: 0.5))
        p.zoom.segments.append(ZoomSegment(id: UUID(uuidString: "5E6A0000-0000-4000-8000-000000000002")!,
                                           start: 0.8, end: 0.95, scale: 1.5, easing: .linear))
        return p
    }

    @Test func roundTrip() throws {
        let project = Self.fullProject()
        let data = try project.jsonData()
        #expect(try StudioProject(jsonData: data) == project)
        // Stable output (sorted keys).
        #expect(try StudioProject(jsonData: data).jsonData() == data)
    }

    @Test func toleratesUnknownFields() throws {
        let data = try Self.fullProject().jsonData()
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["futureSection"] = ["a": 1]
        var cursor = try #require(object["cursor"] as? [String: Any])
        cursor["trail"] = true
        object["cursor"] = cursor
        var zoom = try #require(object["zoom"] as? [String: Any])
        var segments = try #require(zoom["segments"] as? [[String: Any]])
        segments[0]["spring"] = 3
        segments.append(["garbage": true]) // unreadable segment is skipped
        zoom["segments"] = segments
        object["zoom"] = zoom
        let edited = try JSONSerialization.data(withJSONObject: object)
        #expect(try StudioProject(jsonData: edited) == Self.fullProject())
    }

    @Test func missingAndInvalidFieldsFallBackToDefaults() throws {
        let json = #"""
        {"formatVersion": 1,
         "source": {"pixelWidth": 1920, "pixelHeight": 1080, "duration": 12.5},
         "cursor": {"scale": "big", "smoothing": 0.2},
         "camera": {"shape": "hexagon"},
         "canvas": {"aspectRatio": "9:16"}}
        """#
        let p = try StudioProject(jsonData: Data(json.utf8))
        #expect(p.source.pointWidth == 1920)
        #expect(p.source.fps == 60)
        #expect(p.source.media == StudioMediaFiles())
        #expect(p.cursor.scale == StudioCursorSettings.defaultScale)
        #expect(p.cursor.smoothing == 0.2)
        #expect(p.camera.shape == .squircle)
        #expect(p.canvas.aspectRatio == .nineSixteen)
        #expect(p.canvas.outputHeight == 1080)
        #expect(p.zoom == StudioZoomSettings())
        #expect(p.edit == StudioEdit())
        #expect(p.export == StudioExportSettings())
        #expect(p.createdAt == Date(timeIntervalSince1970: 0))
    }

    @Test func rejectsNewerVersion() throws {
        let json = #"{"formatVersion": 2, "source": {"pixelWidth": 10, "pixelHeight": 10, "duration": 1}}"#
        #expect(throws: StudioProjectError.unsupportedFormatVersion(2)) {
            _ = try StudioProject(jsonData: Data(json.utf8))
        }
        #expect(throws: StudioProjectFileError.unsupportedFormatVersion(2)) {
            _ = try StudioProjectFile.decodeProject(Data(json.utf8))
        }
        // Source is required.
        #expect(throws: (any Error).self) {
            _ = try StudioProject(jsonData: Data(#"{"formatVersion": 1}"#.utf8))
        }
    }

    @Test func defaultsMatchPlanAndSettings() {
        let source = StudioSource(pixelWidth: 3840, pixelHeight: 2160, pointWidth: 1920, pointHeight: 1080, duration: 10)
        let p = StudioProject(source: source, defaults: .standard)
        #expect(p.zoom.auto)
        #expect(p.zoom.defaultScale == 2.0)
        #expect(p.cursor.smoothing == 0.6)
        #expect(p.cursor.scale == 1.5)
        #expect(p.cursor.visible && p.cursor.clickEffect && !p.cursor.hideWhenIdle)
        #expect(p.motionBlur == StudioMotionBlur(enabled: true, intensity: 0.5))
        #expect(p.canvas.aspectRatio == .freeform)
        #expect(p.canvas.outputHeight == 1080)
        #expect(p.canvas.padding == 64 && p.canvas.cornerRadius == 12)
        #expect(p.camera.shape == .squircle && p.camera.corner == .bottomRight && !p.camera.mirrored)
        #expect(p.export.format == .mp4 && p.export.codec == .h264 && p.export.quality == .high && p.export.fps == 60)
        #expect(p.canvasPixelSize == CGSize(width: 1920, height: 1080))
        #expect(p.source.pixelsPerPoint == 2)

        let custom = StudioProject(source: source, defaults: StudioProjectDefaults(
            autoZoom: false, defaultZoom: 9, cursorSmoothing: 0.1, motionBlur: false, motionBlurIntensity: 2))
        #expect(!custom.zoom.auto)
        #expect(custom.zoom.defaultScale == ZoomSegment.scaleRange.upperBound) // clamped
        #expect(custom.motionBlur == StudioMotionBlur(enabled: false, intensity: 1))
        #expect(custom.cursor.smoothing == 0.1)
    }

    @Test func normalizationAndHelpers() {
        var p = V1StudioFixture.project()
        p.cursor.scale = 10
        p.camera.size = -1
        p.canvas.outputHeight = 1081
        p.zoom.segments = [ZoomSegment(start: 5, end: 4, scale: 0.2), ZoomSegment(start: 1, end: 2)]
        let n = p.normalized()
        #expect(n.cursor.scale == 3)
        #expect(n.camera.size == StudioCameraSettings.sizeRange.lowerBound)
        #expect(n.canvas.outputHeight == 1080)
        #expect(n.zoom.segments.map(\.start) == [1, 5])
        #expect(n.zoom.segments[1].end == 5 && n.zoom.segments[1].scale == 1)

        #expect(StudioEasing.easeInOutCubic.apply(0) == 0)
        #expect(StudioEasing.easeInOutCubic.apply(0.5) == 0.5)
        #expect(StudioEasing.easeInOutCubic.apply(1) == 1)
        #expect(StudioZoomSpeed.fast.transitionDuration == 0.3)
        #expect(StudioExportSettings(fps: 60).outputFPS(sourceFPS: 30) == 30)
        #expect(abs(p.timeline.outputDuration - 0.7) < 1e-9) // 0.1–0.9 minus 0.4–0.5
        #expect(p.referencedAssets.isEmpty)
    }
}
