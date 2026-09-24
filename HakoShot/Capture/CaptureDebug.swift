#if DEBUG
import CoreGraphics
import Foundation
import HakoKit
import os

/// Smoke test for WP1.1: captures the main display and writes
/// `~/Desktop/HakoShot-debug.png`.
enum CaptureDebug {
    static func captureMainDisplayToDesktop() async {
        let preflight = CGPreflightScreenCaptureAccess()
        Log.capture.notice("debug capture: CGPreflightScreenCaptureAccess = \(preflight)")
        guard preflight else { return }
        do {
            let result = try await ScreenCaptureService.shared.captureDisplay(CGMainDisplayID(), showsCursor: false)
            let data = try ImageEncoder.encode(
                result.image, format: .png, options: .defaults(for: .png, scale: result.scale)
            )
            let url = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Desktop/HakoShot-debug.png")
            try data.write(to: url, options: .atomic)
            ShutterSound.play()
            Log.capture.notice(
                "debug capture: \(result.image.width)x\(result.image.height) px, \(Int(result.pointSize.width))x\(Int(result.pointSize.height)) pt @\(result.scale)x -> \(url.path, privacy: .public)"
            )
        } catch {
            Log.capture.error("debug capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
#endif
