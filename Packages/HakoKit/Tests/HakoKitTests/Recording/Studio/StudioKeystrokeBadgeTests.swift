import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import HakoKit

/// R7.3: keystroke badge in Studio frames and the webcam bubble polish.
@Suite("Studio keystroke badge + camera polish")
struct StudioKeystrokeBadgeTests {
    static let command: UInt64 = 0x100000
    static let yellow = RGBAColor(red: 1, green: 0.85, blue: 0.1)

    /// 1920×1080 source, 1080p canvas, solid background, ⌘Z at 1.0 s and a
    /// plain "a" at 5.0 s.
    static func project(visible: Bool = true, filter: KeystrokeDisplayFilter = .allKeys) -> StudioProject {
        let source = StudioSource(pixelWidth: 1920, pixelHeight: 1080, pointWidth: 960, pointHeight: 540, fps: 30,
                                  duration: 10, cursorBakedIn: false, audioTracks: [])
        var project = StudioProject(source: source, defaults: .standard)
        project.canvas.background.fill = .solid(RGBAColor(red: 0.2, green: 0.4, blue: 0.6))
        project.canvas.background.padding = 60
        project.keystrokes = StudioKeystrokeSettings(visible: visible, filter: filter.rawValue)
        return project
    }

    static let metadata = RecordingMetadata(
        hostTimeOrigin: 1000,
        geometry: RecordingGeometryInfo(rect: CGRect(x: 0, y: 0, width: 960, height: 540), displayID: 1,
                                        scale: 2, pixelWidth: 1920, pixelHeight: 1080),
        keys: [
            RecordingKeyEvent(time: 1.0, keyCode: 0x06, modifierFlags: command, characters: "z"),
            RecordingKeyEvent(time: 5.0, keyCode: 0x00, characters: "a"),
        ],
        cursorBakedIn: false
    )

    static func state(_ project: StudioProject, at t: Double, entries: StudioKeystrokeEntries? = nil) -> StudioFrameState {
        StudioFrameState.make(project: project, metadata: metadata, cursorPath: nil, sourceTime: t, keystrokes: entries)
    }

    static func source(_ size: CGSize = CGSize(width: 1920, height: 1080)) -> CIImage {
        CIImage(color: StudioFrameRenderer.ciColor(yellow)).cropped(to: CGRect(origin: .zero, size: size))
    }

    // MARK: State

    @Test func badgeFadesInHoldsAndFadesOut() throws {
        let project = Self.project()
        let entries = StudioKeystrokeEntries(metadata: Self.metadata, filter: .allKeys)
        #expect(Self.state(project, at: 0.9, entries: entries).keystrokeBadge == nil)
        let fading = try #require(Self.state(project, at: 1.1, entries: entries).keystrokeBadge)
        #expect(abs(fading.alpha - 0.5) < 0.01)
        let full = try #require(Self.state(project, at: 1.5, entries: entries).keystrokeBadge)
        #expect(full.text == "⌘Z")
        #expect(full.alpha == 1)
        #expect(!full.isLight)
        #expect(Self.state(project, at: 2.5, entries: entries).keystrokeBadge == nil)

        // Bottom center of the content card, Medium = 44 px at 1080p.
        let s = Self.state(project, at: 1.5, entries: entries)
        #expect(full.frame.height == 44)
        #expect(abs(full.frame.midX - s.contentRect.midX) < 1)
        #expect(abs(full.frame.maxY - (s.contentRect.maxY - 64)) < 1)

        // Without precomputed entries the same badge is merged on the fly.
        #expect(Self.state(project, at: 1.5).keystrokeBadge == full)
    }

    @Test func badgeHonorsSettings() throws {
        #expect(Self.state(Self.project(visible: false), at: 1.5).keystrokeBadge == nil)

        // Shortcuts only drops the plain "a"; all keys shows it.
        #expect(Self.state(Self.project(filter: .shortcutsOnly), at: 5.2).keystrokeBadge == nil)
        #expect(Self.state(Self.project(filter: .allKeys), at: 5.2).keystrokeBadge != nil)
        // A stale entries cache (other filter) is ignored.
        let stale = StudioKeystrokeEntries(metadata: Self.metadata, filter: .allKeys)
        #expect(Self.state(Self.project(filter: .shortcutsOnly), at: 5.2, entries: stale).keystrokeBadge == nil)

        var project = Self.project()
        project.keystrokes.placement = .topCenter
        project.keystrokes.badgeSize = .large
        project.keystrokes.isLight = true
        let s = Self.state(project, at: 1.5)
        let badge = try #require(s.keystrokeBadge)
        #expect(badge.isLight)
        #expect(badge.frame.height == 56)
        #expect(abs(badge.frame.minY - (s.contentRect.minY + 64)) < 1)
    }

    @Test func settingsRoundTripAndDefaults() throws {
        var project = Self.project(filter: .shortcutsOnly)
        project.camera.border = true
        project.camera.shadow = false
        let decoded = try StudioProject(jsonData: project.jsonData())
        #expect(decoded.keystrokes.displayFilter == .shortcutsOnly)
        #expect(decoded.camera.border)
        #expect(!decoded.camera.shadow)
        // Older files: no filter / shadow / border keys.
        let json = try #require(String(data: StudioProject(source: project.source, defaults: .standard).jsonData(), encoding: .utf8))
        let stripped = json.replacingOccurrences(of: #""filter" : "allKeys","#, with: "")
            .replacingOccurrences(of: #""border" : false,"#, with: "")
        let old = try StudioProject(jsonData: Data(stripped.utf8))
        #expect(old.keystrokes.displayFilter == .allKeys)
        #expect(!old.camera.border)
        #expect(old.camera.shadow)
    }

    // MARK: Pixels

    @Test func badgePixelsAtTheExpectedSpot() throws {
        let renderer = StudioFrameRenderer()
        let project = Self.project()
        let state = Self.state(project, at: 1.5)
        let badge = try #require(state.keystrokeBadge)
        let px = try StudioFrameRendererTests.Pixels(renderer.render(source: Self.source(), state: state))
        // Left cap of the pill (no glyphs there): dark fill over yellow.
        let x = Int(badge.frame.minX + badge.frame.height * 0.3), y = Int(badge.frame.midY)
        let pill = px.at(x, y)
        #expect(pill.r < 130 && pill.g < 120, "dark pill at (\(x), \(y)): \(pill)")
        // Glyphs: some white pixels inside the pill.
        var white = 0
        for gx in Int(badge.frame.minX)..<Int(badge.frame.maxX) {
            let p = px.at(gx, Int(badge.frame.midY))
            if p.r > 200, p.g > 200, p.b > 200 { white += 1 }
        }
        #expect(white > 3, "white glyph pixels on the center row")
        // Above the pill: content untouched.
        #expect(px.matches(x, Int(badge.frame.minY) - 6, Self.yellow))

        // Half faded: between the two.
        let half = try StudioFrameRendererTests.Pixels(renderer.render(source: Self.source(), state: Self.state(project, at: 1.1)))
        let h = half.at(x, y)
        #expect(h.r > pill.r + 40 && h.r < 240, "half alpha \(h)")

        // Hidden.
        let hidden = try StudioFrameRendererTests.Pixels(
            renderer.render(source: Self.source(), state: Self.state(Self.project(visible: false), at: 1.5)))
        #expect(hidden.matches(x, y, Self.yellow))
    }

    @Test func lightBadgeIsLight() throws {
        var project = Self.project()
        project.keystrokes.isLight = true
        let state = Self.state(project, at: 1.5)
        let badge = try #require(state.keystrokeBadge)
        let px = try StudioFrameRendererTests.Pixels(StudioFrameRenderer().render(source: Self.source(), state: state))
        let p = px.at(Int(badge.frame.minX + badge.frame.height * 0.3), Int(badge.frame.midY))
        #expect(p.r > 230 && p.g > 230 && p.b > 220, "light pill \(p)")
    }

    @Test func badgeSitsUnderTheCamera() throws {
        var state = Self.state(Self.project(), at: 1.5)
        let badge = try #require(state.keystrokeBadge)
        let cyan = RGBAColor(red: 0, green: 1, blue: 1)
        state.camera = StudioCameraLayout(rect: badge.frame.insetBy(dx: -20, dy: -20), shape: .rectangle,
                                          cornerRadius: 0, mirrored: false, sourceTime: 0)
        let camera = CIImage(color: StudioFrameRenderer.ciColor(cyan)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        let px = try StudioFrameRendererTests.Pixels(StudioFrameRenderer().render(source: Self.source(), camera: camera, state: state))
        #expect(px.matches(Int(badge.frame.minX + badge.frame.height * 0.3), Int(badge.frame.midY), cyan))
    }

    @Test func cameraShadowDarkensJustOutsideTheBubble() throws {
        let renderer = StudioFrameRendererTests().renderer
        let cyan = RGBAColor(red: 0, green: 1, blue: 1)
        let camera = CIImage(color: StudioFrameRenderer.ciColor(cyan)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        var state = StudioFrameRendererTests.state(corner: 0)
        let rect = CGRect(x: 200, y: 100, width: 60, height: 60)
        state.camera = StudioCameraLayout(rect: rect, shape: .squircle, cornerRadius: 13, mirrored: false, sourceTime: 0)
        let plain = try StudioFrameRendererTests.Pixels(renderer.render(source: StudioFrameRendererTests.quadrantSource(),
                                                                       camera: camera, state: state))
        state.camera?.shadow = StudioFrameState.cameraShadow
        let shadowed = try StudioFrameRendererTests.Pixels(renderer.render(source: StudioFrameRendererTests.quadrantSource(),
                                                                          camera: camera, state: state))
        // 4 px below the bubble's bottom edge (shadow falls 8 down).
        let below = (x: 230, y: Int(rect.maxY) + 4)
        let a = plain.at(below.x, below.y), b = shadowed.at(below.x, below.y)
        #expect(b.r <= a.r && b.g < a.g - 3 && b.b < a.b - 4, "shadow darkens \(a) -> \(b)")
        // Inside the bubble: still the camera.
        #expect(shadowed.matches(230, 130, cyan))
        // Far away: untouched.
        #expect(shadowed.at(60, 60) == plain.at(60, 60))
    }

    @Test func cameraBorderIsWhite() throws {
        let renderer = StudioFrameRenderer()
        let cyan = RGBAColor(red: 0, green: 1, blue: 1)
        let camera = CIImage(color: StudioFrameRenderer.ciColor(cyan)).cropped(to: CGRect(x: 0, y: 0, width: 160, height: 90))
        var state = StudioFrameRendererTests.state(corner: 0)
        state.camera = StudioCameraLayout(rect: CGRect(x: 200, y: 100, width: 60, height: 60), shape: .rectangle,
                                          cornerRadius: 0, mirrored: false, sourceTime: 0, borderWidth: 2)
        let px = try StudioFrameRendererTests.Pixels(renderer.render(source: StudioFrameRendererTests.quadrantSource(),
                                                                    camera: camera, state: state))
        #expect(px.matches(230, 100, .white, tolerance: 20), "top edge \(px.at(230, 100))")
        #expect(px.matches(200, 130, .white, tolerance: 20))
        #expect(px.matches(230, 130, cyan))
        #expect(px.matches(230, 97, StudioFrameRendererTests.green)) // outside: content
    }

    @Test func cameraLayoutCarriesShadowAndBorder() {
        var settings = StudioCameraSettings()
        let on = StudioFrameState.cameraLayoutFor(settings, canvasSize: CGSize(width: 1920, height: 1080), lengthScale: 2, sourceTime: 0)
        #expect(on.shadow.opacity == 0.18)
        #expect(on.shadow.radius == 48)
        #expect(on.borderWidth == 0)
        settings.shadow = false
        settings.border = true
        let off = StudioFrameState.cameraLayoutFor(settings, canvasSize: CGSize(width: 1920, height: 1080), lengthScale: 2, sourceTime: 0)
        #expect(!off.shadow.isVisible)
        #expect(off.borderWidth == 4)
    }
}
