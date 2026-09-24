#if DEBUG
import AppKit
import CoreGraphics
import Foundation
import HakoKit
import os

/// Smoke test for WP3.1: captures the frontmost app's front window with the
/// current window settings and writes `~/Desktop/HakoShot-window-debug.png`.
/// Wiring (URL `debug-capture-front-window`, launch argument) is in the WP3.1
/// report.
enum WindowCaptureDebug {
    /// `-HakoWindowCaptureDebug`: run once at launch. Optional
    /// `-HakoWindowCaptureDebugBackground transparent|wallpaper|solidColor`
    /// and `-HakoWindowCaptureDebugShadow 0|1` override the settings.
    static let launchArgument = "-HakoWindowCaptureDebug"
    static let backgroundArgument = "-HakoWindowCaptureDebugBackground"
    static let shadowArgument = "-HakoWindowCaptureDebugShadow"

    static var defaultOutputURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Desktop/HakoShot-window-debug.png")
    }

    /// Call from `applicationDidFinishLaunching`; does nothing without `launchArgument`.
    static func runFromLaunchArgumentsIfRequested(_ arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard arguments.contains(launchArgument) else { return }
        var options = AppSettings.shared.windowCaptureOptions
        switch value(after: backgroundArgument, in: arguments).flatMap(WindowCaptureBackgroundKind.init(rawValue:)) {
        case .transparent: options.background = .transparent
        case .wallpaper: options.background = .wallpaper
        case .solidColor: options.background = .solid(.white)
        case nil: break
        }
        if let shadow = value(after: shadowArgument, in: arguments) { options.includesShadow = shadow != "0" }
        Task { await captureFrontmostWindowToDesktop(options: options) }
    }

    /// Returns the written file URL, or `nil` on failure (logged).
    @discardableResult
    static func captureFrontmostWindowToDesktop(
        options: WindowCaptureOptions = AppSettings.shared.windowCaptureOptions,
        to url: URL = defaultOutputURL
    ) async -> URL? {
        let preflight = CGPreflightScreenCaptureAccess()
        Log.capture.notice("debug window capture: CGPreflightScreenCaptureAccess = \(preflight)")
        guard preflight else { return nil }
        let locator = WindowLocator.snapshot()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let window = locator.frontmostWindow(preferringPID: frontPID) else {
            Log.capture.error("debug window capture: no eligible window")
            return nil
        }
        do {
            let result = try await ScreenCaptureService.shared.captureWindow(window.id, options: options)
            let data = try ImageEncoder.encode(result.image, format: .png, options: .defaults(for: .png, scale: result.scale))
            try data.write(to: url, options: .atomic)
            Log.capture.notice(
                "debug window capture: '\(window.displayName, privacy: .public)' frame \(Int(window.frame.width))x\(Int(window.frame.height)) pt -> \(result.image.width)x\(result.image.height) px @\(result.scale)x alpha=\(result.image.alphaInfo.rawValue) shadow=\(options.includesShadow) -> \(url.path, privacy: .public)"
            )
            return url
        } catch {
            Log.capture.error("debug window capture failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
#endif
