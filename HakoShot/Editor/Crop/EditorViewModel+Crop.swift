import CoreGraphics
import Foundation
import HakoKit

extension SettingsKey where Value == Bool {
    /// Crop mode "Snap to edges" checkbox (report §9.4).
    static var editorCropSnapToEdges: SettingsKey<Bool> { SettingsKey("editorCropSnapToEdges", default: true) }
}

/// Crop mode (WP5.1, report §9.4). Non-destructive: the session edits a rect
/// in display pixels (uncropped image, rotate/flip applied); applying writes
/// `document.crop` with one `setCrop` undo step.
extension EditorViewModel {
    var isCropping: Bool { cropSession != nil }

    /// K / capsule button: enter crop mode, or leave it without applying.
    func toggleCropMode() {
        if isCropping { cancelCrop() } else { beginCrop() }
    }

    func beginCrop() {
        commitTextEditing?()
        guard !isCropping else { return }
        if !store.selection.isEmpty { perform(.clearSelection) }
        cropSession = CropSession(document: store.document, snapping: settings.value(for: .editorCropSnapToEdges))
    }

    /// Esc / Cancel.
    func cancelCrop() {
        cropSession = nil
    }

    /// Return / Crop button: one undo step ("Crop").
    func applyCrop() {
        guard let session = cropSession else { return }
        let crop = CropMath.canvasCrop(for: session.rect, in: store.document)
        cropSession = nil
        if crop != store.document.crop { perform(.setCrop(crop)) }
    }

    func updateCrop(_ body: (inout CropSession) -> Void) {
        guard var session = cropSession else { return }
        body(&session)
        cropSession = session
    }

    func setCropSnapping(_ on: Bool) {
        settings.set(on, for: .editorCropSnapToEdges)
        updateCrop { $0.snapping = on }
    }

    /// Crop-bar size label ("Image size: 1964 × 1186 px").
    var cropImageSize: CGSize { cropSession?.bounds.size ?? DocumentRenderer.contentSize(of: store.document) }

    // MARK: Rotate / flip (crop bar)

    /// Rotates the visible result by 90° (clockwise or not), one undo step.
    func rotate(clockwise: Bool) {
        var t = store.document.transform
        // Rotation is applied before the flips, so one flip reverses its sense.
        let mirrored = t.flipHorizontal != t.flipVertical
        let step = (clockwise != mirrored) ? 1 : 3
        t = CanvasTransform(rotationQuarterTurns: t.rotationQuarterTurns + step,
                            flipHorizontal: t.flipHorizontal, flipVertical: t.flipVertical)
        setTransformKeepingCrop(t)
    }

    /// Mirrors the visible result, one undo step.
    func flip(horizontal: Bool) {
        var t = store.document.transform
        if horizontal { t.flipHorizontal.toggle() } else { t.flipVertical.toggle() }
        setTransformKeepingCrop(t)
    }

    /// Applies `transform`; an open crop session keeps the same image area.
    private func setTransformKeepingCrop(_ transform: CanvasTransform) {
        let old = store.document
        perform(.setTransform(transform))
        guard var session = cropSession else { return }
        let canvasRect = session.rect.applying(CropMath.displayTransform(of: old).inverted())
        let new = store.document
        let fresh = CropSession(document: new, snapping: session.snapping)
        session.bounds = fresh.bounds
        session.targets = fresh.targets
        session.rect = CropMath.rounded(canvasRect.applying(CropMath.displayTransform(of: new))).intersection(fresh.bounds)
        if case .ratio(let w, let h) = session.aspect, transform.rotationQuarterTurns != old.transform.rotationQuarterTurns {
            session.aspect = .ratio(width: h, height: w)
        }
        cropSession = session
    }
}
