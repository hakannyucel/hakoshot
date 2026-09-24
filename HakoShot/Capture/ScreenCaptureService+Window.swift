import AppKit
import CoreGraphics
import Foundation
import HakoKit
import ImageIO
import os
@preconcurrency import ScreenCaptureKit

/// Window capture (plan §1.3, §4.4): one window, independent of what covers
/// it, with or without its drop shadow, on a transparent / wallpaper / solid
/// background.
extension ScreenCaptureService {
    /// Captures window `id` (`kCGWindowNumber`, e.g. `LocatedWindow.id`).
    ///
    /// Output size is `SCShareableContent.info(for:).contentRect ×
    /// pointPixelScale` (the window frame) — plus the shadow margins when the
    /// shadow is kept, and `2 × padding × scale` for a non-transparent
    /// background.
    ///
    /// `contentRect` excludes the shadow and ScreenCaptureKit scales the
    /// shadowed window down to fit the requested size, so shadowed captures
    /// use a canvas `shadowCanvasMargin` larger with `scalesToFit = false`
    /// (content lands 1:1 at the top-left) and are then trimmed to their
    /// alpha extent (`WindowShadowTrim`).
    func captureWindow(_ id: CGWindowID, options: WindowCaptureOptions = .default) async throws -> CaptureResult {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
        // Fresh fetch: the window list changes constantly and the cached
        // content may predate the window.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureError.captureFailed("window \(id) is not on screen")
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let info = SCShareableContent.info(for: filter)
        let scale = CGFloat(info.pointPixelScale)
        let frameWidth = Int((info.contentRect.width * scale).rounded())
        let frameHeight = Int((info.contentRect.height * scale).rounded())
        let margin = options.includesShadow ? Int((Self.shadowCanvasMargin * scale).rounded()) : 0
        let config = SCStreamConfiguration()
        config.width = frameWidth + margin
        config.height = frameHeight + margin
        config.ignoreShadowsSingleWindow = !options.includesShadow
        config.shouldBeOpaque = false
        config.showsCursor = options.showsCursor
        config.captureResolution = .best
        config.scalesToFit = false
        guard config.width > 0, config.height > 0 else { throw CaptureError.emptyRect }

        let windowFrame = window.frame
        let rawImage = try await Self.shootWindow(WindowShot(filter: filter, config: config))
        let windowImage = options.includesShadow ? WindowShadowTrim.trimmed(rawImage) : rawImage
        Log.capture.debug(
            "window \(id): frame \(Int(windowFrame.width))x\(Int(windowFrame.height)) pt, content \(Int(info.contentRect.width))x\(Int(info.contentRect.height)) pt @\(scale)x -> \(windowImage.width)x\(windowImage.height) px"
        )

        let layout = await DisplayLayoutProvider.currentLayout()
        let displayID = ScreenGeometry.display(containing: CGPoint(x: windowFrame.midX, y: windowFrame.midY), layout: layout)?.id

        let image: CGImage
        switch options.background {
        case .transparent:
            image = windowImage
        case let .solid(color):
            image = try Self.backdrop(windowImage, options: options, scale: scale, backdrop: .color(color))
        case .wallpaper:
            let wallpaper = await wallpaperImage(for: displayID, content: content)
            image = try Self.backdrop(windowImage, options: options, scale: scale, backdrop: wallpaper.map(WindowBackdrop.image) ?? .color(.white))
        }

        return CaptureResult(
            image: image,
            pointSize: CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale),
            scale: scale, mode: .window, sourceRect: nil, displayID: displayID
        )
    }

    /// Extra canvas (points, per axis) for the shadow. Measured on macOS 26:
    /// inactive windows 23 pt left/right, 16 top, 30 bottom (+46 / +46 per
    /// axis); the key window 56 pt left/right, 38 top, 74 bottom (+112 / +112).
    static let shadowCanvasMargin: CGFloat = 200

    // MARK: Helpers

    private static func backdrop(_ window: CGImage, options: WindowCaptureOptions, scale: CGFloat, backdrop: WindowBackdrop) throws -> CGImage {
        let padding = Int((max(options.padding, 0) * scale).rounded())
        guard let image = WindowBackdropCompositor.composite(window: window, padding: padding, backdrop: backdrop) else {
            throw CaptureError.compositingFailed
        }
        return image
    }

    /// The desktop picture of `displayID`: the file from
    /// `NSWorkspace.desktopImageURL(for:)`, or — for dynamic/aerial
    /// wallpapers that aren't a plain image file — a capture of the system
    /// wallpaper window alone.
    private func wallpaperImage(for displayID: CGDirectDisplayID?, content: SCShareableContent) async -> CGImage? {
        let url: URL? = await MainActor.run {
            let screen = displayID.flatMap(DisplayLayoutProvider.screen(for:)) ?? NSScreen.main
            return screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        }
        if let url, let image = Self.loadImage(at: url) { return image }
        if let image = try? await wallpaperWindowImage(for: displayID ?? CGMainDisplayID(), content: content) { return image }
        Log.capture.warning("wallpaper unavailable (\(url?.path ?? "no URL", privacy: .public)); using white")
        return nil
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        // Dynamic HEICs hold several frames; the primary one is the current look closely enough.
        let index = CGImageSourceGetPrimaryImageIndex(source)
        return CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Captures only the wallpaper window(s) on `displayID` (owned by Dock /
    /// WallpaperAgent, below the desktop icons).
    private func wallpaperWindowImage(for displayID: CGDirectDisplayID, content: SCShareableContent) async throws -> CGImage? {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let wallpaperWindows = content.windows.filter { window in
            let bundleID = window.owningApplication?.bundleIdentifier ?? ""
            let isWallpaperOwner = bundleID == "com.apple.dock" || bundleID == "com.apple.wallpaper.agent"
            return isWallpaperOwner && window.windowLayer < 0 && window.frame.intersects(display.frame)
        }
        guard !wallpaperWindows.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: wallpaperWindows)
        let info = SCShareableContent.info(for: filter)
        let config = SCStreamConfiguration()
        config.width = Int((info.contentRect.width * CGFloat(info.pointPixelScale)).rounded())
        config.height = Int((info.contentRect.height * CGFloat(info.pointPixelScale)).rounded())
        config.showsCursor = false
        config.captureResolution = .best
        return try await Self.shootWindow(WindowShot(filter: filter, config: config))
    }

    private static func shootWindow(_ shot: WindowShot) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: shot.filter, configuration: shot.config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.captureFailed(error?.localizedDescription ?? "no image"))
                }
            }
        }
    }
}

/// Filter + configuration handed to ScreenCaptureKit once, never mutated
/// afterwards (neither type is `Sendable`).
private nonisolated struct WindowShot: @unchecked Sendable {
    let filter: SCContentFilter
    let config: SCStreamConfiguration
}
