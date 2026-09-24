import AppKit
import CoreGraphics
import Foundation
import HakoKit
import Testing
@testable import HakoShot

// R1.2 session UI: control bar placement (pure), timer text formatting, and
// countdown cancellation.

@Suite("Recording control bar layout")
struct RecordingControlBarLayoutTests {
    let barSize = CGSize(width: 300, height: 40)
    let displayFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    @Test func defaultIsBottomCenterOfTheDisplay() {
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: displayFrame, recordedRect: nil)
        #expect(origin == CGPoint(x: 810, y: 24))
        #expect(origin.x + barSize.width / 2 == displayFrame.midX)
        #expect(origin.y == Tokens.Recording.controlBarBottomInset)
    }

    @Test func recordedRectFarFromTheBottomDoesNotMoveTheBar() {
        // Well clear of the default bar rect (x 810...1110, y 24...64).
        let recordedRect = CGRect(x: 100, y: 500, width: 400, height: 300)
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: displayFrame, recordedRect: recordedRect)
        #expect(origin == CGPoint(x: 810, y: 24))
    }

    @Test func overlapWithRoomBelowMovesUnderneathTheRect() {
        // Overlaps the default bar rect (y 24...64) but leaves room below it.
        let recordedRect = CGRect(x: 700, y: 60, width: 600, height: 500)
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: displayFrame, recordedRect: recordedRect)
        let expectedX = recordedRect.midX - barSize.width / 2
        let expectedY = recordedRect.minY - RecordingControlBarLayout.rectGap - barSize.height
        #expect(origin == CGPoint(x: expectedX, y: expectedY))
        #expect(origin.y >= displayFrame.minY)
        // The bar no longer overlaps the recorded rect.
        #expect(!CGRect(origin: origin, size: barSize).intersects(recordedRect))
    }

    @Test func overlapWithNoRoomBelowMovesAboveTheRect() {
        // Touches the display's bottom edge: no room underneath it.
        let recordedRect = CGRect(x: 700, y: 0, width: 600, height: 500)
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: displayFrame, recordedRect: recordedRect)
        let expectedX = recordedRect.midX - barSize.width / 2
        let expectedY = recordedRect.maxY + RecordingControlBarLayout.rectGap
        #expect(origin == CGPoint(x: expectedX, y: expectedY))
        #expect(origin.y + barSize.height <= displayFrame.maxY)
        #expect(!CGRect(origin: origin, size: barSize).intersects(recordedRect))
    }

    @Test func fullscreenRecordedRectFallsBackToTheDefaultSpot() {
        // The recorded rect fills the whole display (fullscreen target): no
        // room above or below, so the bar overlaps it at the default spot —
        // harmless, since our own windows never appear in the recording.
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: displayFrame, recordedRect: displayFrame)
        #expect(origin == CGPoint(x: 810, y: 24))
    }

    @Test func horizontalPlacementClampsToTheDisplay() {
        // Overlaps the default bar rect, and centering under the (very wide,
        // left-heavy) recorded rect would push the bar off the left edge.
        let recordedRect = CGRect(x: -1000, y: 60, width: 1900, height: 500)
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: displayFrame, recordedRect: recordedRect)
        let expectedY = recordedRect.minY - RecordingControlBarLayout.rectGap - barSize.height
        #expect(origin == CGPoint(x: displayFrame.minX, y: expectedY))
    }

    @Test func secondaryDisplayWithNegativeOriginKeepsTheBarOnThatDisplay() {
        // A display to the left of, and below, the main display.
        let secondary = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        let origin = RecordingControlBarLayout.origin(barSize: barSize, displayFrame: secondary, recordedRect: nil)
        #expect(origin == CGPoint(x: -1110, y: -176))
        #expect(origin.x + barSize.width / 2 == secondary.midX)
        #expect(origin.y == secondary.minY + Tokens.Recording.controlBarBottomInset)
        // The bar stays fully inside its own display, not the main one at (0, 0).
        #expect(secondary.contains(CGRect(origin: origin, size: barSize)))
    }
}

@Suite("Recording timer text")
struct RecordingTimerTextTests {
    @Test func matchesQuickAccessDurationFormat() {
        for seconds in [0.0, 1.4, 59.6, 84, 3599, 3661, 36_030] {
            #expect(RecordingControlBar.timerText(elapsed: seconds) == QuickAccessDurationFormat.string(seconds: seconds))
        }
    }

    @Test func minutesSecondsAndHours() {
        #expect(RecordingControlBar.timerText(elapsed: 0) == "0:00")
        #expect(RecordingControlBar.timerText(elapsed: 84) == "1:24")
        #expect(RecordingControlBar.timerText(elapsed: 3661) == "1:01:01")
    }

    @Test func menuBarIndicatorUsesTheSameFormatting() {
        #expect(RecordingMenuBarIndicator.timeText(elapsed: 84) == RecordingControlBar.timerText(elapsed: 84))
    }

    @Test @MainActor func menuBarModelHidesTimeUnlessTheSettingIsOn() {
        let model = RecordingMenuBarIndicatorModel(isRecording: true, isPaused: false, elapsed: 84, showsTime: false)
        #expect(model.timeText == nil)
        model.showsTime = true
        #expect(model.timeText == "1:24")
        model.isRecording = false
        #expect(model.timeText == nil)
    }
}

@Suite("Recording countdown", .serialized)
struct RecordingCountdownTests {
    @Test @MainActor func cancelStopsTheCountdownAndReturnsFalse() async {
        let countdown = RecordingCountdown()
        let rect = GlobalRect(x: 100, y: 100, width: 400, height: 300)
        let run = Task { await countdown.run(seconds: 5, on: rect) }
        try? await Task.sleep(for: .milliseconds(250))
        #expect(countdown.isRunning)
        #expect(countdown.windowID != nil)
        countdown.cancel()
        let completed = await run.value
        #expect(completed == false)
        #expect(!countdown.isRunning)
        #expect(countdown.windowID == nil)
    }

    @Test @MainActor func runningTwiceReturnsFalseImmediatelyForTheSecondCall() async {
        let countdown = RecordingCountdown()
        let rect = GlobalRect(x: 0, y: 0, width: 400, height: 300)
        let first = Task { await countdown.run(seconds: 3, on: rect) }
        try? await Task.sleep(for: .milliseconds(150))
        let second = await countdown.run(seconds: 3, on: rect)
        #expect(second == false)
        countdown.cancel()
        _ = await first.value
    }
}
