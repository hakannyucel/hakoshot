import CoreGraphics
import Foundation
@testable import HakoShot

/// Shared fixtures for `OutputService`/`ClipboardWriter`/`PostCaptureRouter`
/// tests: a tiny solid-color `CGImage` and a scratch `AppSettings` +
/// directory that never touch the real `~/Desktop` or `UserDefaults.standard`.
enum PostCaptureFixture {
    /// A `pointWidth` × `pointHeight` (points) `CGImage` at `scale`×, i.e.
    /// `pointWidth * scale` × `pointHeight * scale` pixels — matching how
    /// `CaptureResult` relates `pointSize` to `image`.
    static func image(pointWidth: Int = 4, pointHeight: Int = 3, scale: CGFloat = 2) -> CGImage {
        let width = Int(CGFloat(pointWidth) * scale)
        let height = Int(CGFloat(pointHeight) * scale)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    static func captureResult(
        mode: CaptureMode = .area,
        pointWidth: Int = 4,
        pointHeight: Int = 3,
        scale: CGFloat = 2,
        date: Date = Date(timeIntervalSince1970: 1_726_000_000)
    ) -> CaptureResult {
        CaptureResult(
            image: image(pointWidth: pointWidth, pointHeight: pointHeight, scale: scale),
            pointSize: CGSize(width: pointWidth, height: pointHeight),
            scale: scale,
            mode: mode,
            date: date
        )
    }

    /// A throwaway `AppSettings` backed by a uniquely-named `UserDefaults`
    /// suite. Call `cleanup()` (e.g. in a `defer`) to remove its persistent
    /// domain afterward.
    final class ScratchSettings {
        let suiteName = "com.hakanyucel.hakoshot.tests.\(UUID().uuidString)"
        let settings: AppSettings

        init() {
            let defaults = UserDefaults(suiteName: suiteName)!
            settings = AppSettings(defaults: defaults)
        }

        func cleanup() {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
    }

    /// A unique scratch directory under the system temp directory. Call
    /// `cleanup()` (e.g. in a `defer`) to remove it afterward.
    final class ScratchDirectory {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hakoshot-tests-\(UUID().uuidString)", isDirectory: true)

        func cleanup() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
