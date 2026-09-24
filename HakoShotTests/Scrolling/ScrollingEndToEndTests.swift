import AppKit
import Foundation
import HakoKit
import Testing
@testable import HakoShot

/// Real stream + stitcher + UI against a window of another process. Opt-in:
/// runs only when `HAKO_SCROLL_E2E_DIR` is set (pass it to xcodebuild as
/// `TEST_RUNNER_HAKO_SCROLL_E2E_DIR`). The directory holds `rect.txt`
/// ("x,y,w,h", Quartz global points) written by the harness app; the test
/// creates `go` to make the harness scroll itself, waits for `done`, presses
/// Done and writes `out.png` + `out.txt`. With `HAKO_SCROLL_E2E_AUTO=1` it
/// uses auto-scroll instead (skipped when event posting isn't permitted, so
/// no permission prompt appears).
@Suite("Scrolling: end to end", .serialized)
struct ScrollingEndToEndTests {
    nonisolated static let directory = ProcessInfo.processInfo.environment["HAKO_SCROLL_E2E_DIR"]
    nonisolated static let auto = ProcessInfo.processInfo.environment["HAKO_SCROLL_E2E_AUTO"] == "1"

    @Test(.enabled(if: directory != nil), .timeLimit(.minutes(2)))
    func harnessWindowIsStitched() async throws {
        let dir = URL(fileURLWithPath: try #require(Self.directory))
        let rectText = try String(contentsOf: dir.appending(path: "rect.txt"), encoding: .utf8)
        let rect = try #require(ScrollingCaptureDebug.parseRect(rectText.trimmingCharacters(in: .whitespacesAndNewlines)))
        try #require(CGPreflightScreenCaptureAccess(), "test host has no Screen Recording permission")
        if Self.auto {
            try #require(AutoScroller.isPermitted, "event posting not permitted; auto path skipped")
        }

        if let still = try? await ScreenCaptureService.shared.captureRect(rect, showsCursor: false),
           let data = try? ImageEncoder.encode(still.image, format: .png, options: .defaults(for: .png, scale: still.scale)) {
            try data.write(to: dir.appending(path: "still.png"))
        }
        let flow = ScrollingCaptureFlow()
        let driver = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            if !Self.auto {
                FileManager.default.createFile(atPath: dir.appending(path: "go").path, contents: Data())
                let doneFile = dir.appending(path: "done").path
                for _ in 0..<600 where !FileManager.default.fileExists(atPath: doneFile) {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(1))
                flow.requestDone()
            } else {
                // Safety net; auto-scroll finishes by itself at the end.
                try? await Task.sleep(for: .seconds(90))
                flow.requestDone()
            }
        }
        let started = Date()
        let result = await flow.run(rect: rect, autoScroll: Self.auto, start: true)
        driver.cancel()
        let captured = try #require(result)
        let data = try ImageEncoder.encode(captured.image, format: .png, options: .defaults(for: .png, scale: captured.scale))
        try data.write(to: dir.appending(path: "out.png"))
        let summary = "\(captured.image.width)x\(captured.image.height) px, \(captured.pointSize.width)x\(captured.pointSize.height) pt @\(captured.scale)x, \(String(format: "%.1f", Date().timeIntervalSince(started))) s\n"
        try summary.write(to: dir.appending(path: "out.txt"), atomically: true, encoding: .utf8)
        #expect(captured.mode == .scrolling)
        #expect(CGFloat(captured.image.height) > rect.height * captured.scale * 2)
    }
}
