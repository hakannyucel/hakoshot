import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("RecordingGeometry")
struct RecordingGeometryTests {
    @Test func retinaAreaDoublesPoints() {
        let size = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 640, height: 360), backingScale: 2)
        #expect(size.width == 1280)
        #expect(size.height == 720)
    }

    @Test func scaleTo1xUsesPoints() {
        let size = RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: 640, height: 360), backingScale: 2, scaleTo1x: true
        )
        #expect(size.width == 640)
        #expect(size.height == 360)
        let plan = RecordingGeometry.plan(pointSize: CGSize(width: 640, height: 360), backingScale: 2, scaleTo1x: true)
        #expect(plan.effectiveScale == 1)
    }

    @Test func oddSizesFloorToEven() {
        let oneX = RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: 641, height: 361), backingScale: 2, scaleTo1x: true
        )
        #expect(oneX.width == 640)
        #expect(oneX.height == 360)
        // Fractional points × 1.5 (scaled display).
        let frac = RecordingGeometry.outputPixelSize(pointSize: CGSize(width: 333.5, height: 101), backingScale: 1.5)
        #expect(frac.width == 500) // 500.25
        #expect(frac.height == 150) // 151.5 → 151 → 150
        #expect(RecordingGeometry.evenFloor(1) == 2)
        #expect(RecordingGeometry.evenFloor(0) == 2)
        #expect(RecordingGeometry.evenFloor(.nan) == 2)
        #expect(RecordingGeometry.evenFloor(7.9) == 6)
    }

    @Test func fiveKDisplaySwitchesToHEVCByDefault() {
        let plan = RecordingGeometry.plan(pointSize: CGSize(width: 2560, height: 1440), backingScale: 2)
        #expect(plan.pixelWidth == 5120)
        #expect(plan.pixelHeight == 2880)
        #expect(plan.codec == .hevc)
        #expect(plan.didSwitchToHEVC)
        #expect(!plan.didDownscaleForH264)
        #expect(plan.effectiveScale == 2)
    }

    @Test func fiveKWithDownscalePolicyStaysH264() {
        let plan = RecordingGeometry.plan(
            pointSize: CGSize(width: 2560, height: 1440), backingScale: 2, h264Overflow: .downscale
        )
        #expect(plan.codec == .h264)
        #expect(plan.didDownscaleForH264)
        #expect(plan.pixelWidth == 4096)
        #expect(plan.pixelHeight == 2304)
        #expect(RecordingGeometry.fitsH264(width: plan.pixelWidth, height: plan.pixelHeight))
        #expect(plan.effectiveScale == 1.6)
    }

    @Test func hevcRequestIsNeverChanged() {
        let plan = RecordingGeometry.plan(pointSize: CGSize(width: 2560, height: 1440), backingScale: 2, codec: .hevc)
        #expect(plan.codec == .hevc)
        #expect(!plan.didSwitchToHEVC)
        #expect(plan.pixelWidth == 5120)
    }

    @Test func h264Limit() {
        #expect(RecordingGeometry.fitsH264(width: 3840, height: 2160))
        #expect(RecordingGeometry.fitsH264(width: 4096, height: 2304))
        #expect(!RecordingGeometry.fitsH264(width: 4096, height: 2320))
        #expect(!RecordingGeometry.fitsH264(width: 5120, height: 2880))
        #expect(!RecordingGeometry.fitsH264(width: 4112, height: 100)) // over max dimension
        // 9:16 slice of a 5K display fits.
        #expect(RecordingGeometry.fitsH264(width: 1620, height: 2880))
        let plan = RecordingGeometry.plan(pointSize: CGSize(width: 1920, height: 1080), backingScale: 2)
        #expect(plan.codec == .h264)
        #expect(!plan.didSwitchToHEVC)
    }

    @Test func h264FittingSizeKeepsRatioAndFits() {
        let portrait = RecordingGeometry.h264FittingSize(width: 2880, height: 5120)
        #expect(portrait.width == 2304)
        #expect(portrait.height == 4096)
        let odd = RecordingGeometry.h264FittingSize(width: 6016, height: 3384) // Pro Display XDR
        #expect(RecordingGeometry.fitsH264(width: odd.width, height: odd.height))
        #expect(odd.width % 2 == 0 && odd.height % 2 == 0)
        #expect(abs(Double(odd.width) / Double(odd.height) - 6016.0 / 3384.0) < 0.01)
        let fits = RecordingGeometry.h264FittingSize(width: 1280, height: 720)
        #expect(fits.width == 1280 && fits.height == 720)
    }

    @Test func maxResolutionCapsShortSide() {
        // 5K fullscreen, 1080p cap → 1920×1080, fits H.264.
        let plan = RecordingGeometry.plan(
            pointSize: CGSize(width: 2560, height: 1440), backingScale: 2, maxResolution: .p1080
        )
        #expect(plan.pixelWidth == 1920)
        #expect(plan.pixelHeight == 1080)
        #expect(plan.codec == .h264)
        #expect(plan.effectiveScale == 0.75)
        // 4K cap on 5K → 3840×2160.
        let fourK = RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: 2560, height: 1440), backingScale: 2, maxResolution: .p2160
        )
        #expect(fourK.width == 3840 && fourK.height == 2160)
        // Portrait: short side is the width.
        let portrait = RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: 810, height: 1440), backingScale: 2, maxResolution: .p720
        )
        #expect(portrait.width == 720)
        #expect(portrait.height == 1280)
    }

    @Test func maxResolutionNeverUpscales() {
        let size = RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: 640, height: 360), backingScale: 2, maxResolution: .p1080
        )
        #expect(size.width == 1280 && size.height == 720)
        #expect(RecordingResolutionCap.original.shortSideLimit == nil)
        #expect(RecordingResolutionCap.allCases.count == 5)
    }

    @Test func maxResolutionWithOddResultStaysEven() {
        // 1001×1000 px capped to 720 short side → 720.72 → 720.
        let size = RecordingGeometry.outputPixelSize(
            pointSize: CGSize(width: 1001, height: 1000), backingScale: 1, maxResolution: .p720
        )
        #expect(size.width == 720)
        #expect(size.height == 720)
    }
}

@Suite("RecordingAspectRatio")
struct RecordingAspectRatioTests {
    @Test func presetsIncludeFiveFourAndNineSixteen() {
        #expect(RecordingAspectRatio.hudPresets.contains(.fiveFour))
        #expect(RecordingAspectRatio.hudPresets.contains(.nineSixteen))
        #expect(RecordingAspectRatio.studioPresets.contains(.nineSixteen))
        #expect(RecordingAspectRatio.studioPresets.contains(.fourFive))
        #expect(RecordingAspectRatio.hudPresets.map(\.description) == [
            "freeform", "1:1", "4:3", "5:4", "3:2", "16:9", "16:10", "9:16",
        ])
    }

    @Test func mathAndParsing() {
        #expect(RecordingAspectRatio.fiveFour.height(forWidth: 1000) == 800)
        #expect(RecordingAspectRatio.nineSixteen.width(forHeight: 1600) == 900)
        #expect(RecordingAspectRatio.freeform.value == nil)
        #expect(RecordingAspectRatio(label: "16:10") == .sixteenTen)
        #expect(RecordingAspectRatio(label: "Auto") == .freeform)
        #expect(RecordingAspectRatio(label: "0:1") == nil)
        #expect(RecordingAspectRatio(label: "abc") == nil)
        let fit = RecordingAspectRatio.nineSixteen.largestSize(fittingIn: CGSize(width: 1920, height: 1080))
        #expect(fit == CGSize(width: 607.5, height: 1080))
        let wide = RecordingAspectRatio.sixteenNine.largestSize(fittingIn: CGSize(width: 1000, height: 1000))
        #expect(wide == CGSize(width: 1000, height: 562.5))
    }

    @Test func studioCanvasSizes() {
        let src = CGSize(width: 2560, height: 1600)
        #expect(RecordingAspectRatio.sixteenNine.canvasPixelSize(outputHeight: 1080, sourceSize: src) == (1920, 1080))
        #expect(RecordingAspectRatio.nineSixteen.canvasPixelSize(outputHeight: 1080, sourceSize: src) == (608, 1080))
        #expect(RecordingAspectRatio.freeform.canvasPixelSize(outputHeight: 1080, sourceSize: src) == (1728, 1080))
    }

    @Test func codableAsLabel() throws {
        let data = try JSONEncoder().encode([RecordingAspectRatio.fiveFour, .freeform])
        #expect(String(decoding: data, as: UTF8.self) == #"["5:4","freeform"]"#)
        #expect(try JSONDecoder().decode([RecordingAspectRatio].self, from: data) == [.fiveFour, .freeform])
    }
}
