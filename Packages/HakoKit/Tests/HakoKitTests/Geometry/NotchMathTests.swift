import Testing
import CoreGraphics
@testable import HakoKit

@Suite("NotchMath")
struct NotchMathTests {
    // MARK: hasNotch

    @Test func safeAreaInsetMeansNotch() {
        #expect(NotchMath.hasNotch(safeAreaTopInset: 37.5, auxiliaryTopLeft: nil, auxiliaryTopRight: nil))
    }

    @Test func auxiliaryAreasMeanNotch() {
        let left = CGRect(x: -1710, y: 1402.5, width: 751, height: 37.5)
        let right = CGRect(x: -751, y: 1402.5, width: 751, height: 37.5)
        #expect(NotchMath.hasNotch(safeAreaTopInset: 0, auxiliaryTopLeft: left, auxiliaryTopRight: right))
    }

    @Test func externalDisplayHasNoNotch() {
        #expect(!NotchMath.hasNotch(safeAreaTopInset: 0, auxiliaryTopLeft: nil, auxiliaryTopRight: nil))
    }

    @Test func singleAuxiliaryAreaIsNotANotch() {
        let left = CGRect(x: 0, y: 0, width: 700, height: 30)
        #expect(!NotchMath.hasNotch(safeAreaTopInset: 0, auxiliaryTopLeft: left, auxiliaryTopRight: nil))
    }

    // MARK: topCropInset

    @Test func measuredMacBookPro14() {
        // macOS 27, built-in 1710×1112 pt @2x: safe area 37.5 pt → 75 px.
        let inset = NotchMath.topCropInset(safeAreaTopInset: 37.5, auxiliaryTopHeight: 37.5, displayHeight: 1112, scale: 2)
        #expect(inset == 37.5)
        #expect(inset * 2 == 75)
    }

    @Test func noNotchCropsNothing() {
        #expect(NotchMath.topCropInset(safeAreaTopInset: 0, auxiliaryTopHeight: nil, displayHeight: 1440, scale: 2) == 0)
    }

    @Test func roundsUpToWholePixels() {
        // 32.3 pt @2x = 64.6 px → 65 px → 32.5 pt.
        #expect(NotchMath.topCropInset(safeAreaTopInset: 32.3, auxiliaryTopHeight: nil, displayHeight: 1000, scale: 2) == 32.5)
        // @1x rounds to whole points.
        #expect(NotchMath.topCropInset(safeAreaTopInset: 32.3, auxiliaryTopHeight: nil, displayHeight: 1000, scale: 1) == 33)
    }

    @Test func floatNoiseDoesNotAddARow() {
        #expect(NotchMath.topCropInset(safeAreaTopInset: 37.5000001, auxiliaryTopHeight: nil, displayHeight: 1112, scale: 2) == 37.5)
    }

    @Test func usesTallerOfSafeAreaAndAuxiliary() {
        #expect(NotchMath.topCropInset(safeAreaTopInset: 32, auxiliaryTopHeight: 38, displayHeight: 1112, scale: 2) == 38)
        #expect(NotchMath.topCropInset(safeAreaTopInset: 0, auxiliaryTopHeight: 38, displayHeight: 1112, scale: 2) == 38)
    }

    @Test func degenerateInputsCropNothing() {
        #expect(NotchMath.topCropInset(safeAreaTopInset: 40, auxiliaryTopHeight: nil, displayHeight: 30, scale: 2) == 0)
        #expect(NotchMath.topCropInset(safeAreaTopInset: 40, auxiliaryTopHeight: nil, displayHeight: 1000, scale: 0) == 0)
        #expect(NotchMath.topCropInset(safeAreaTopInset: -5, auxiliaryTopHeight: nil, displayHeight: 1000, scale: 2) == 0)
    }

    // MARK: croppedFrame

    @Test func croppedFrameKeepsNonZeroOrigin() {
        let frame = GlobalRect(x: -1710, y: 328, width: 1710, height: 1112)
        #expect(NotchMath.croppedFrame(frame, topInset: 37.5) == GlobalRect(x: -1710, y: 365.5, width: 1710, height: 1074.5))
    }

    @Test func croppedFrameClampsInset() {
        let frame = GlobalRect(x: 0, y: 0, width: 100, height: 50)
        #expect(NotchMath.croppedFrame(frame, topInset: -3) == frame)
        #expect(NotchMath.croppedFrame(frame, topInset: 80).height == 0)
    }
}
