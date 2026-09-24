import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("StudioFrameState")
struct StudioFrameStateTests {
    /// Fixture project with 54 pt padding: on the 1280×720 canvas the
    /// length scale is 2/3, padding 36 px, content 1152×648 at (64, 36),
    /// 9 canvas px per source px.
    static func project(camera: Bool = false) -> StudioProject {
        var p = V1StudioFixture.project()
        p.canvas.padding = 54
        p.cursor.smoothing = 0
        p.cursor.hideWhenIdle = false
        if camera { p.source.media.camera = "camera.mov" }
        return p
    }

    static func path(for p: StudioProject) -> CursorPath {
        CursorPath(samples: V1StudioFixture.samples(), clicks: V1StudioFixture.metadata().clicks, smoothing: p.cursor.smoothing)
    }

    struct HalfViewport: StudioViewport {
        func viewRect(atSourceTime t: Double, sourceSize: CGSize) -> CGRect {
            CGRect(x: 0, y: 0, width: sourceSize.width / 2, height: sourceSize.height / 2)
        }
    }

    @Test func layoutAtKnownTime() throws {
        let p = Self.project()
        let state = StudioFrameState.make(project: p, metadata: V1StudioFixture.metadata(),
                                          cursorPath: Self.path(for: p), outputTime: 0.45)
        // Output 0.45 = 0.3 s of [0.1, 0.4) + 0.15 s into [0.5, 0.9).
        #expect(abs(state.sourceTime - 0.65) < 1e-9)
        #expect(state.outputTime == 0.45)
        #expect(state.canvasSize == CGSize(width: 1280, height: 720))
        #expect(abs(state.lengthScale - 2.0 / 3.0) < 1e-12)
        #expect(state.contentRect == CGRect(x: 64, y: 36, width: 1152, height: 648))
        #expect(state.viewRect == CGRect(x: 0, y: 0, width: 128, height: 72))
        #expect(state.zoomScale == 1)
        #expect(abs(state.cornerRadius - 8 * 2.0 / 3.0) < 1e-9)
        #expect(state.background == .solid(RGBAColor(red: 0.2, green: 0.4, blue: 0.6)))
        #expect(abs(state.shadow.radius - 16) < 1e-9) // 24 pt × 2/3

        // Cursor at x = 60·t pt = 39 pt, y = 9 pt → source (78, 18) px.
        let cursor = try #require(state.cursor)
        #expect(abs(cursor.sourcePosition.x - 78) < 1e-4 && abs(cursor.sourcePosition.y - 18) < 1e-4)
        #expect(abs(cursor.position.x - 766) < 1e-3 && abs(cursor.position.y - 198) < 1e-3)
        #expect(cursor.scale == 36) // size 2 × 2 px/pt × 9
        #expect(cursor.opacity == 1)
        #expect(cursor.shapeIndex == 0)
        // Click at 0.5 s is 0.15 s into its 0.35 s ring.
        #expect(state.clickEffects.count == 1)
        #expect(abs((state.clickEffects.first?.progress ?? 0) - 0.15 / 0.35) < 1e-9)
        #expect(state.camera == nil)
    }

    @Test func clickEffectProgress() throws {
        let p = Self.project()
        let state = StudioFrameState.make(project: p, metadata: V1StudioFixture.metadata(),
                                          cursorPath: Self.path(for: p), sourceTime: 0.6)
        #expect(state.outputTime.isFinite)
        let effect = try #require(state.clickEffects.first)
        #expect(state.clickEffects.count == 1)
        #expect(abs(effect.progress - 0.1 / 0.35) < 1e-9)
        #expect(effect.position == CGPoint(x: 64 + 32 * 9, y: 36 + 18 * 9))
        let eased = StudioEasing.easeOutCubic.apply(0.1 / 0.35)
        #expect(abs(effect.radius - (18 + 12 * eased) * 2.0 / 3.0) < 1e-9)
        #expect(abs(effect.opacity - (1 - 0.1 / 0.35)) < 1e-9)

        var off = p
        off.cursor.clickEffect = false
        #expect(StudioFrameState.make(project: off, metadata: V1StudioFixture.metadata(),
                                      cursorPath: Self.path(for: off), sourceTime: 0.6).clickEffects.isEmpty)
    }

    @Test func bakedInCursorIsNotDrawn() {
        var p = Self.project()
        p.source.cursorBakedIn = true
        let state = StudioFrameState.make(project: p, metadata: V1StudioFixture.metadata(),
                                          cursorPath: Self.path(for: p), sourceTime: 0.6)
        #expect(state.cursor == nil)
        #expect(state.clickEffects.isEmpty)
        #expect(state.contentRect == CGRect(x: 64, y: 36, width: 1152, height: 648)) // layout unaffected

        var hidden = Self.project()
        hidden.cursor.visible = false
        #expect(StudioFrameState.make(project: hidden, metadata: nil, cursorPath: Self.path(for: hidden),
                                      sourceTime: 0.6).cursor == nil)
        #expect(StudioFrameState.make(project: Self.project(), metadata: nil, cursorPath: nil,
                                      sourceTime: 0.6).cursor == nil)
    }

    @Test func hideWhenIdleFades() throws {
        var p = Self.project()
        p.source.duration = 10
        p.edit = StudioEdit()
        p.cursor.hideWhenIdle = true
        p.cursor.idleDelay = 2
        // Cursor stops at 1 s.
        let path = CursorPath(samples: V1StudioFixture.samples(), smoothing: 0)
        func opacity(_ t: Double) -> Double? {
            StudioFrameState.make(project: p, metadata: nil, cursorPath: path, sourceTime: t).cursor?.opacity
        }
        #expect(opacity(2.5) == 1)
        #expect(abs((opacity(3.15) ?? 0) - 0.5) < 1e-6)
        #expect(opacity(4) == nil)
    }

    @Test func cameraLayout() throws {
        let p = Self.project(camera: true)
        var metadata = V1StudioFixture.metadata()
        metadata.cameraTimeOffset = -0.05
        let state = StudioFrameState.make(project: p, metadata: metadata, cursorPath: nil, sourceTime: 0.6)
        let camera = try #require(state.camera)
        // side = 0.18 × 720 ≈ 130, margin 24 × 2/3 = 16, bottom-right.
        #expect(camera.rect == CGRect(x: 1134, y: 574, width: 130, height: 130))
        #expect(abs(camera.cornerRadius - 130 * 0.22) < 1e-9)
        #expect(camera.shape == .squircle && !camera.mirrored)
        #expect(abs(camera.sourceTime - 0.55) < 1e-9)

        let vertical = StudioFrameState.cameraLayoutFor(
            StudioCameraSettings(shape: .vertical, size: 0.2, corner: .topLeft), canvasSize: CGSize(width: 1920, height: 1080),
            lengthScale: 1, sourceTime: 0)
        #expect(vertical.rect == CGRect(x: 24, y: 24, width: 216, height: 384))

        var hidden = p
        hidden.camera.visible = false
        #expect(StudioFrameState.make(project: hidden, metadata: metadata, cursorPath: nil, sourceTime: 0.6).camera == nil)
    }

    @Test func viewportHookZooms() throws {
        let p = Self.project()
        let state = StudioFrameState.make(project: p, metadata: V1StudioFixture.metadata(),
                                          cursorPath: Self.path(for: p), sourceTime: 0.3, viewport: HalfViewport())
        #expect(state.viewRect == CGRect(x: 0, y: 0, width: 64, height: 36))
        #expect(state.zoomScale == 2)
        // Cursor at 18 pt → 36 source px → 64 + 36 × 18.
        let cursor = try #require(state.cursor)
        #expect(abs(cursor.position.x - (64 + 36 * 18)) < 1e-3)
        #expect(cursor.scale == 72)
    }

    @Test func contentRectForPortraitAndAuto() {
        var p = Self.project()
        p.canvas.aspectRatio = .nineSixteen
        p.canvas.outputHeight = 1080
        p.canvas.padding = 0
        let portrait = StudioFrameState.make(project: p, metadata: nil, cursorPath: nil, sourceTime: 0)
        #expect(portrait.canvasSize == CGSize(width: 608, height: 1080))
        #expect(portrait.contentRect == CGRect(x: 0, y: 369, width: 608, height: 342))

        p.canvas.aspectRatio = .freeform
        let auto = StudioFrameState.make(project: p, metadata: nil, cursorPath: nil, sourceTime: 0)
        #expect(auto.canvasSize == CGSize(width: 1920, height: 1080))
        #expect(auto.contentRect == auto.canvasRect)
    }
}
