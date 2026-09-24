import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

// R5.2 live overlays: the window is click-through, capturable and has an ID;
// the rendered ring is #0A84FF at the model radius; the badge follows the
// layout; tokens and HakoKit defaults agree.

@MainActor
@Suite("Recording overlay window", .serialized)
struct RecordingOverlayWindowTests {
    static var mainDisplay: CGDirectDisplayID { CGMainDisplayID() }

    static func makeOverlay(_ tweak: (inout RecordingOverlayAppearance) -> Void = { _ in }) throws -> RecordingOverlayWindow {
        var appearance = RecordingOverlayAppearance.default
        appearance.showsKeystrokes = true
        tweak(&appearance)
        return try #require(RecordingOverlayWindow(displayID: mainDisplay, appearance: appearance))
    }

    /// RGBA (unpremultiplied, 0…255) at image pixel (x, y), y from the top.
    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = data.assumingMemoryBound(to: UInt8.self)
        let a = Double(p[3])
        guard a > 0 else { return (0, 0, 0, 0) }
        return (Double(p[0]) * 255 / a, Double(p[1]) * 255 / a, Double(p[2]) * 255 / a, a)
    }

    @Test func windowIsClickThroughCapturableAndHasAnID() throws {
        let overlay = try Self.makeOverlay()
        defer { overlay.close() }
        // The panel is created with `defer: false`, so it has a window number
        // (and an ID) before it's ordered in.
        #expect(overlay.windowID != nil)
        overlay.show()
        #expect(overlay.isVisible)
        let window = overlay.window
        #expect(window.ignoresMouseEvents)
        #expect(!window.isOpaque)
        #expect(window.backgroundColor == .clear)
        #expect(window.styleMask.contains(.borderless))
        #expect(window.styleMask.contains(.nonactivatingPanel))
        #expect(!window.canBecomeKey)
        #expect(window.sharingType != .none)        // must stay capturable
        #expect(window.level == RecordingOverlayWindow.level)
        #expect(window.frame == NSScreen.screens.first { $0.frame.origin == .zero }?.frame ?? window.frame)
        let id = try #require(overlay.windowID)
        #expect(id > 0)
        #expect(id == CGWindowID(window.windowNumber))
    }

    @Test(arguments: [0.0, 0.1])
    func ringPixelsAreClickBlue(at t: Double) throws {
        let overlay = try Self.makeOverlay()
        defer { overlay.close() }
        let bounds = overlay.displayBounds
        let click = CGPoint(x: bounds.minX + 400, y: bounds.minY + 300)
        overlay.showClick(at: click, button: .left)
        let image = try #require(overlay.snapshot(at: t))
        let scale = Double(image.width) / Double(bounds.width)
        let radius = overlay.appearance.clickModel.radius(at: t)

        // On the ring's center line, right of the click.
        let px = Int(((400 + radius) * scale).rounded(.down))
        let py = Int((300 * scale).rounded(.down))
        let ring = try #require(Self.pixel(image, px, py))
        // #0A84FF = (10, 132, 255).
        #expect(abs(ring.r - 10) <= 8, "r \(ring.r)")
        #expect(abs(ring.g - 132) <= 8, "g \(ring.g)")
        #expect(abs(ring.b - 255) <= 8, "b \(ring.b)")
        let expectedAlpha = overlay.appearance.clickModel.alpha(at: t) * 255
        #expect(abs(ring.a - expectedAlpha) <= 10, "a \(ring.a) vs \(expectedAlpha)")

        // Outline style: the center stays transparent.
        let center = try #require(Self.pixel(image, Int(400 * scale), py))
        #expect(center.a == 0)
        // Nothing past the ring.
        let outside = try #require(Self.pixel(image, Int((400 + radius + 6) * scale), py))
        #expect(outside.a == 0)
    }

    @Test func ringIsGoneAfterTheDuration() throws {
        let overlay = try Self.makeOverlay()
        defer { overlay.close() }
        let bounds = overlay.displayBounds
        overlay.showClick(at: CGPoint(x: bounds.minX + 400, y: bounds.minY + 300), button: .left)
        let image = try #require(overlay.snapshot(at: 0.35))
        let scale = Double(image.width) / Double(bounds.width)
        let radius = ClickEffectModel.defaultEndRadius
        let ring = try #require(Self.pixel(image, Int((400 + radius) * scale), Int(300 * scale)))
        #expect(ring.a == 0)
    }

    @Test func filledStyleFillsTheCenter() throws {
        let overlay = try Self.makeOverlay { $0.clickStyle = .filled }
        defer { overlay.close() }
        let bounds = overlay.displayBounds
        overlay.showClick(at: CGPoint(x: bounds.minX + 400, y: bounds.minY + 300), button: .left)
        let image = try #require(overlay.snapshot(at: 0))
        let scale = Double(image.width) / Double(bounds.width)
        let center = try #require(Self.pixel(image, Int(400 * scale), Int(300 * scale)))
        #expect(abs(center.a - 0.35 * 255) <= 6)
        #expect(abs(center.b - 255) <= 10)
    }

    @Test func clicksOffTheDisplayOrDisabledAreIgnored() throws {
        let overlay = try Self.makeOverlay()
        defer { overlay.close() }
        overlay.showClick(at: CGPoint(x: overlay.displayBounds.maxX + 50, y: 10), button: .left)
        #expect(overlay.activeRippleCount == 0)
        let off = try Self.makeOverlay { $0.highlightsClicks = false; $0.showsKeystrokes = false }
        defer { off.close() }
        off.showClick(at: CGPoint(x: off.displayBounds.midX, y: off.displayBounds.midY), button: .left)
        off.showKeystroke("⌘Z")
        #expect(off.activeRippleCount == 0)
        #expect(off.keystrokeLabel == nil)
    }

    @Test func badgeRendersAtTheLayoutFrameAndCountsRepeats() throws {
        let overlay = try Self.makeOverlay()
        defer { overlay.close() }
        overlay.showKeystroke("⌘Z", time: 100)
        overlay.showKeystroke("⌘Z", time: 100.4)
        #expect(overlay.keystrokeLabel == "⌘Z ×2")
        overlay.showKeystroke("⌘S", time: 100.8)
        #expect(overlay.keystrokeLabel == "⌘S")

        // Fully faded in 0.3 s after the latest press.
        let image = try #require(overlay.snapshot(at: 0.3))
        let bounds = overlay.displayBounds
        let scale = Double(image.width) / Double(bounds.width)
        let metrics = overlay.appearance.badgeMetrics
        let frame = KeystrokeBadgeLayout.frame(text: "⌘S", metrics: metrics, placement: .bottomCenter,
                                               in: CGRect(origin: .zero, size: bounds.size))
        // Left edge of the pill, vertically centered: dark fill.
        let fill = try #require(Self.pixel(image, Int((frame.minX + 4) * scale), Int(frame.midY * scale)))
        #expect(fill.a > 150)
        #expect(fill.r < 60 && fill.g < 60 && fill.b < 60)
        // Just below the pill: transparent.
        let below = try #require(Self.pixel(image, Int(frame.midX * scale), Int((frame.maxY + 4) * scale)))
        #expect(below.a == 0)
        // Some white glyph pixel inside the text area.
        var foundWhite = false
        let row = Int(frame.midY * scale)
        for x in Int(frame.minX * scale)..<Int(frame.maxX * scale) {
            if let p = Self.pixel(image, x, row), p.a > 200, p.r > 200, p.g > 200, p.b > 200 { foundWhite = true; break }
        }
        #expect(foundWhite)

        overlay.clear()
        #expect(overlay.keystrokeLabel == nil)
    }

    @Test func badgeRegionMovesTheBadge() throws {
        let overlay = try Self.makeOverlay { $0.keystrokePosition = .topCenter }
        defer { overlay.close() }
        let bounds = overlay.displayBounds
        let area = CGRect(x: bounds.minX + 200, y: bounds.minY + 150, width: 600, height: 400)
        overlay.badgeRegion = area
        overlay.showKeystroke("⎋", time: 50)
        let image = try #require(overlay.snapshot(at: 0.3))
        let scale = Double(image.width) / Double(bounds.width)
        let frame = KeystrokeBadgeLayout.frame(text: "⎋", metrics: overlay.appearance.badgeMetrics, placement: .topCenter,
                                               in: CGRect(x: 200, y: 150, width: 600, height: 400))
        #expect(abs(frame.minY - 214) < 1e-6)
        let fill = try #require(Self.pixel(image, Int((frame.minX + frame.height / 2) * scale), Int(frame.midY * scale)))
        #expect(fill.a > 150)
    }
}

@Suite("Recording overlay appearance")
struct RecordingOverlayAppearanceTests {
    @Test func tokensMatchTheHakoKitDefaults() {
        let appearance = RecordingOverlayAppearance.default
        #expect(appearance.clickModel == ClickEffectModel.standard)
        for size in RecordingElementSize.allCases {
            let kitSize = RecordingOverlaySize(rawValue: size.rawValue)!
            #expect(Double(Tokens.Recording.clickScale(size)) == ClickEffectModel.sizeScale(kitSize))
            var a = appearance
            a.keystrokeSize = size
            #expect(a.badgeMetrics == KeystrokeBadgeMetrics.standard(kitSize))
        }
        #expect(appearance.badgeTiming == KeystrokeBadgeTiming.standard)
    }

    @Test func enumsMapByRawValue() {
        for position in KeystrokeBadgePosition.allCases {
            #expect(KeystrokeBadgePlacement(rawValue: position.rawValue) != nil)
        }
        for filter in KeystrokeFilter.allCases {
            #expect(KeystrokeDisplayFilter(rawValue: filter.rawValue) != nil)
        }
        for style in ClickHighlightStyle.allCases {
            #expect(ClickEffectStyle(rawValue: style.rawValue) != nil)
        }
    }

    @MainActor
    @Test func readsSettings() throws {
        let suite = "com.hakanyucel.hakoshot.tests.overlay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(RecordingOverlayAppearance(settings: settings) == .default)
        settings.set("#FF0000", for: .recordingClickColor)
        settings.set(KeystrokeBadgeStyle.light, for: .recordingKeystrokeStyle)
        settings.set(KeystrokeFilter.allKeys, for: .recordingKeystrokeFilter)
        let custom = RecordingOverlayAppearance(settings: settings)
        #expect(custom.clickColor == RGBAColor(red: 1, green: 0, blue: 0))
        #expect(custom.badgeFill == Tokens.Recording.keystrokeLightFill)
        #expect(custom.displayFilter == .allKeys)
    }

    @Test func debugParameters() throws {
        #if DEBUG
        let p = try #require(OverlayDemoDebug.Parameters(queryItems: [
            URLQueryItem(name: "x", value: "100"), URLQueryItem(name: "y", value: "80"),
            URLQueryItem(name: "snapshot", value: "/tmp/x"),
        ]))
        #expect(p.point == CGPoint(x: 100, y: 80))
        #expect(p.snapshotDir?.path == "/tmp/x")
        #expect(p.keys == "⇧⌘F")
        #expect(p.button == .left)
        #expect(OverlayDemoDebug.Parameters(queryItems: [URLQueryItem(name: "x", value: "1")]) == nil)
        #endif
    }
}
