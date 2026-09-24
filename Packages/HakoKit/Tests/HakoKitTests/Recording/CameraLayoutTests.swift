import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("CameraLayout")
struct CameraLayoutTests {
    let bounds = CGRect(x: 100, y: 50, width: 1280, height: 720)

    // MARK: Size

    @Test(arguments: [140.0, 180.0, 240.0])
    func squareShapesUseTheSettingAsTheSide(side: Double) {
        #expect(CameraLayout.bubbleSize(shortSide: side, shape: .squircle, fitting: bounds.size) == CGSize(width: side, height: side))
        #expect(CameraLayout.bubbleSize(shortSide: side, shape: .circle) == CGSize(width: side, height: side))
    }

    @Test func rectangleIs16by9AndVerticalIs9by16() {
        let rect = CameraLayout.bubbleSize(shortSide: 180, shape: .rectangle, fitting: bounds.size)
        #expect(rect == CGSize(width: 320, height: 180))
        let vertical = CameraLayout.bubbleSize(shortSide: 180, shape: .vertical, fitting: bounds.size)
        #expect(vertical == CGSize(width: 180, height: 320))
    }

    @Test func largeBubbleShrinksInASmallRecordedArea() {
        // 400×300 area: shorter side ≤ 150 (50 %).
        let size = CameraLayout.bubbleSize(shortSide: 240, shape: .squircle, fitting: CGSize(width: 400, height: 300))
        #expect(size == CGSize(width: 150, height: 150))
        // Vertical 9:16 in a short area: height must fit 300 − 2 × 24.
        let vertical = CameraLayout.bubbleSize(shortSide: 240, shape: .vertical, fitting: CGSize(width: 400, height: 300))
        #expect(vertical.height <= 252)
        #expect(abs(vertical.width / vertical.height - 9.0 / 16.0) < 0.01)
    }

    // MARK: Placement

    @Test func defaultCornerIsBottomRightWithMarginYDown() {
        let size = CGSize(width: 180, height: 180)
        let frame = CameraLayout.frame(size: size, corner: .bottomRight, in: bounds)
        #expect(frame == CGRect(x: 100 + 1280 - 24 - 180, y: 50 + 720 - 24 - 180, width: 180, height: 180))
    }

    @Test func cornersInAppKitSpaceFlipY() {
        let size = CGSize(width: 180, height: 180)
        let bottomRight = CameraLayout.frame(size: size, corner: .bottomRight, in: bounds, yAxis: .up)
        #expect(bottomRight.minY == bounds.minY + 24)
        #expect(bottomRight.maxX == bounds.maxX - 24)
        let topLeft = CameraLayout.frame(size: size, corner: .topLeft, in: bounds, yAxis: .up)
        #expect(topLeft.maxY == bounds.maxY - 24)
        #expect(topLeft.minX == bounds.minX + 24)
    }

    @Test func matchesStudioCameraLayoutFor() {
        // Same rect as the Studio render for a canvas-sized bounds, k = 1.
        let canvas = CGSize(width: 1920, height: 1080)
        for corner in StudioCameraCorner.allCases {
            for shape in StudioCameraShape.allCases {
                let settings = StudioCameraSettings(shape: shape, size: 0.18, corner: corner)
                let studio = StudioFrameState.cameraLayoutFor(settings, canvasSize: canvas, lengthScale: 1, sourceTime: 0)
                let size = CameraLayout.bubbleSize(shortSide: (0.18 * 1080).rounded(), shape: shape)
                let ours = CameraLayout.frame(size: size, corner: corner, in: CGRect(origin: .zero, size: canvas))
                #expect(ours == studio.rect, "\(shape) \(corner)")
                #expect(CameraLayout.cornerRadius(shape: shape, size: size) == studio.cornerRadius, "\(shape)")
            }
        }
    }

    @Test(arguments: [
        (CGPoint(x: 150, y: 80), StudioCameraCorner.topLeft),
        (CGPoint(x: 1300, y: 80), .topRight),
        (CGPoint(x: 150, y: 700), .bottomLeft),
        (CGPoint(x: 1300, y: 700), .bottomRight),
    ])
    func nearestCornerByQuadrant(center: CGPoint, expected: StudioCameraCorner) {
        let frame = CGRect(x: center.x - 20, y: center.y - 20, width: 40, height: 40)
        #expect(CameraLayout.nearestCorner(to: frame, in: bounds) == expected)
    }

    @Test func nearestCornerAppKit() {
        // y up: small y = bottom.
        let frame = CGRect(x: 120, y: 60, width: 40, height: 40)
        #expect(CameraLayout.nearestCorner(to: frame, in: bounds, yAxis: .up) == .bottomLeft)
        #expect(CameraLayout.nearestCorner(to: frame, in: bounds, yAxis: .down) == .topLeft)
    }

    @Test func snapMovesToTheNearestCornerWithMargin() {
        let dropped = CGRect(x: 300, y: 500, width: 180, height: 180)  // lower-left quadrant (y down)
        let result = CameraLayout.snapped(dropped, in: bounds)
        #expect(result.corner == .bottomLeft)
        #expect(result.frame == CGRect(x: 124, y: 50 + 720 - 24 - 180, width: 180, height: 180))
    }

    // MARK: Clamp

    @Test func clampKeepsTheBubbleInside() {
        let outside = CGRect(x: -500, y: 2000, width: 180, height: 180)
        let clamped = CameraLayout.clamp(outside, in: bounds)
        #expect(clamped == CGRect(x: 100, y: 50 + 720 - 180, width: 180, height: 180))
        #expect(bounds.contains(clamped))
        let inside = CGRect(x: 400, y: 300, width: 180, height: 180)
        #expect(CameraLayout.clamp(inside, in: bounds) == inside)
    }

    @Test func dragPastTheEdgeStopsAtTheEdge() {
        let start = CameraLayout.frame(size: CGSize(width: 180, height: 180), corner: .bottomRight, in: bounds)
        let dragged = CameraLayout.dragged(start, by: CGVector(dx: 5000, dy: 5000), in: bounds)
        #expect(dragged.maxX == bounds.maxX)
        #expect(dragged.maxY == bounds.maxY)
        #expect(bounds.contains(dragged))
    }

    @Test func frameLargerThanBoundsIsCentered() {
        let big = CGRect(x: 0, y: 0, width: 2000, height: 100)
        let clamped = CameraLayout.clamp(big, in: bounds)
        #expect(clamped.midX == bounds.midX)
        #expect(clamped.width == 2000)
    }

    // MARK: Shape

    @Test func cornerRadiusPerShape() {
        let square = CGSize(width: 180, height: 180)
        #expect(CameraLayout.cornerRadius(shape: .circle, size: square) == 90)
        #expect(abs(CameraLayout.cornerRadius(shape: .squircle, size: square) - 39.6) < 1e-9)
        #expect(CameraLayout.cornerRadius(shape: .rectangle, size: CGSize(width: 320, height: 180)) == 12)
        #expect(CameraLayout.cornerRadius(shape: .vertical, size: CGSize(width: 180, height: 320)) == 12)
        #expect(CameraLayout.cornerRadius(shape: .rectangle, size: CGSize(width: 16, height: 9), rectangleRadius: 12) == 4.5)
    }

    @Test func maskExcludesCornersAndIncludesCenter() {
        let rect = CGRect(x: 0, y: 0, width: 180, height: 180)
        for shape in [StudioCameraShape.circle, .squircle] {
            #expect(CameraLayout.maskContains(CGPoint(x: 90, y: 90), shape: shape, in: rect))
            #expect(!CameraLayout.maskContains(CGPoint(x: 2, y: 2), shape: shape, in: rect))
            #expect(!CameraLayout.maskContains(CGPoint(x: 178, y: 178), shape: shape, in: rect))
        }
        // Circle cuts deeper than the squircle at the 45° point.
        let probe = CGPoint(x: 20, y: 20)
        #expect(!CameraLayout.maskContains(probe, shape: .circle, in: rect))
        #expect(CameraLayout.maskContains(probe, shape: .squircle, in: rect))
        // Rectangle: tiny radius, (5, 5) is inside.
        #expect(CameraLayout.maskContains(CGPoint(x: 5, y: 5), shape: .rectangle, in: CGRect(x: 0, y: 0, width: 320, height: 180)))
    }

    @Test func aspectFillCropCentersTheSource() {
        let crop = CameraLayout.aspectFillCrop(source: CGSize(width: 1280, height: 720), bubble: CGSize(width: 180, height: 180))
        #expect(crop == CGRect(x: 280, y: 0, width: 720, height: 720))
        let vertical = CameraLayout.aspectFillCrop(source: CGSize(width: 1280, height: 720), bubble: CGSize(width: 90, height: 160))
        #expect(abs(vertical.width - 405) < 1e-9)
        #expect(vertical.height == 720)
        #expect(abs(vertical.midX - 640) < 1e-9)
    }

    // MARK: Time

    @Test func cameraTimeOffsetMapsScreenTimeToCameraTime() {
        // Camera started 0.25 s before the first screen frame.
        let offset = CameraLayout.cameraTimeOffset(screenOrigin: 100.25, cameraOrigin: 100.0)
        #expect(offset == 0.25)
        // Screen t = 1 → host 101.25 → camera t = 1.25.
        #expect(1.0 + offset == 101.25 - 100.0)
    }
}
