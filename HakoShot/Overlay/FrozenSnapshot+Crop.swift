import CoreGraphics
import HakoKit

extension FrozenSnapshot {
    /// The snapshot's pixels for `rect` (Quartz global points on this
    /// display); `nil` if `rect` doesn't overlap the display. No capture.
    func cropped(to rect: GlobalRect) -> CGImage? {
        SnapshotCrop.crop(image, to: rect, displayFrame: displayFrame, scale: scale)
    }

    /// A finished capture for a `.frozenArea` outcome, cropped from this
    /// snapshot instead of capturing the screen again (plan §4.2).
    func captureResult(for rect: GlobalRect, mode: CaptureMode) -> CaptureResult? {
        guard let cropped = cropped(to: rect) else { return nil }
        let s = max(scale, 1)
        return CaptureResult(
            image: cropped,
            pointSize: CGSize(width: CGFloat(cropped.width) / s, height: CGFloat(cropped.height) / s),
            scale: scale,
            mode: mode,
            sourceRect: rect,
            displayID: displayID
        )
    }
}
