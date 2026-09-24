import CoreGraphics
import Foundation
import HakoKit
import os
@preconcurrency import ScreenCaptureKit

nonisolated enum CaptureError: LocalizedError, Equatable {
    case permissionDenied
    case emptyRect
    case noDisplay
    case displayNotFound(CGDirectDisplayID)
    case captureFailed(String)
    case compositingFailed

    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is not granted."
        case .emptyRect: "The selected area is empty or off-screen."
        case .noDisplay: "No display is available."
        case let .displayNotFound(id): "Display \(id) is not available for capture."
        case let .captureFailed(reason): "Capture failed: \(reason)"
        case .compositingFailed: "Could not combine the captured displays."
        }
    }
}

/// Takes still images through ScreenCaptureKit (plan §1.3, §3.2).
///
/// Every capture excludes HakoShot's own windows (overlay, Quick Access, HUD,
/// pins): the content filter excludes the `SCRunningApplication` whose
/// `processID` is this process, so windows created after the content was
/// fetched are excluded too. Rects that span several displays are captured
/// per display (each with that exclusion) and composited at the highest
/// scale — `SCScreenshotManager.captureImage(in:)` can't exclude windows.
actor ScreenCaptureService {
    static let shared = ScreenCaptureService()

    private let contentCache = ShareableContentCache()
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    /// Leave desktop icons and widgets out of captures (`DesktopIconFilter`).
    /// Set before each capture from Settings or the "Hide Desktop Icons" toggle.
    private var hidesDesktopIcons = false

    func setHidesDesktopIcons(_ on: Bool) { hidesDesktopIcons = on }

    // MARK: Shareable content

    /// Call on launch (after permission is granted) to prefetch content.
    func warmUp() async {
        guard CGPreflightScreenCaptureAccess() else { return }
        do { try await contentCache.refresh() } catch {
            Log.capture.error("warm-up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Call when a capture hotkey fires, in parallel with showing the overlay.
    func refreshShareableContent() async {
        await warmUp()
    }

    // MARK: Captures

    /// Captures `rect` (Quartz global points). The image is `rect.size ×
    /// scale` pixels, where scale is the largest backing scale among the
    /// displays the rect touches.
    func captureRect(_ rect: GlobalRect, showsCursor: Bool, mode: CaptureMode = .area) async throws -> CaptureResult {
        try checkPermission()
        let layout = await DisplayLayoutProvider.currentLayout()
        guard let plan = CapturePlan.make(rect: rect, layout: layout) else { throw CaptureError.emptyRect }
        let content = try await resolvedContent()

        let image: CGImage
        if plan.isSingleDisplay, let piece = plan.pieces.first {
            let filter = try makeFilter(displayID: piece.displayID, content: content)
            image = try await Self.shoot(filter, sourceRect: piece.sourceRect, width: piece.pixelWidth, height: piece.pixelHeight, showsCursor: showsCursor)
        } else {
            var parts: [(CGImage, CGRect)] = []
            for piece in plan.pieces {
                let filter = try makeFilter(displayID: piece.displayID, content: content)
                let part = try await Self.shoot(filter, sourceRect: piece.sourceRect, width: piece.pixelWidth, height: piece.pixelHeight, showsCursor: showsCursor)
                parts.append((part, piece.destination))
            }
            image = try Self.composite(parts, width: plan.pixelWidth, height: plan.pixelHeight)
        }

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let displayID = ScreenGeometry.display(containing: center, layout: layout)?.id ?? plan.pieces.first?.displayID
        logSize(image, expectedWidth: plan.pixelWidth, expectedHeight: plan.pixelHeight)
        return CaptureResult(
            image: image, pointSize: rect.size, scale: plan.outputScale, mode: mode,
            sourceRect: rect, displayID: displayID
        )
    }

    /// Captures a whole display at its native pixel size.
    /// - Parameter topInsetToCrop: points to cut from the top (notch, plan
    ///   §4.6; pass `NotchCropper.topInsetToCrop(for:settings:)`).
    func captureDisplay(
        _ displayID: CGDirectDisplayID,
        showsCursor: Bool,
        mode: CaptureMode = .fullscreen(.activeDisplay),
        topInsetToCrop: CGFloat = 0
    ) async throws -> CaptureResult {
        try checkPermission()
        let layout = await DisplayLayoutProvider.currentLayout()
        guard let display = layout.display(withID: displayID),
              let frame = ScreenGeometry.globalFrame(of: display, layout: layout)
        else { throw CaptureError.displayNotFound(displayID) }

        let inset = min(max(topInsetToCrop, 0), frame.height)
        let rect = GlobalRect(x: frame.minX, y: frame.minY + inset, width: frame.width, height: frame.height - inset)
        guard rect.height > 0 else { throw CaptureError.emptyRect }
        let scale = display.backingScaleFactor
        let width = Int(CapturePlan.pixels(rect.width, scale))
        let height = Int(CapturePlan.pixels(rect.height, scale))

        let content = try await resolvedContent()
        let filter = try makeFilter(displayID: displayID, content: content)
        let sourceRect = inset > 0 ? CGRect(x: 0, y: inset, width: rect.width, height: rect.height) : nil
        let image = try await Self.shoot(filter, sourceRect: sourceRect, width: width, height: height, showsCursor: showsCursor)
        logSize(image, expectedWidth: width, expectedHeight: height)
        return CaptureResult(
            image: image, pointSize: rect.size, scale: scale, mode: mode,
            sourceRect: rect, displayID: displayID
        )
    }

    /// Captures every display in parallel, for Freeze Screen (plan §4.2).
    func snapshotAllDisplays() async throws -> [FrozenSnapshot] {
        try checkPermission()
        let layout = await DisplayLayoutProvider.currentLayout()
        guard !layout.displays.isEmpty else { throw CaptureError.noDisplay }
        let content = try await resolvedContent()

        var jobs: [(FilterBox, DisplayDescriptor, GlobalRect)] = []
        for display in layout.displays {
            guard let frame = ScreenGeometry.globalFrame(of: display, layout: layout) else { continue }
            jobs.append((FilterBox(filter: try makeFilter(displayID: display.id, content: content)), display, frame))
        }

        return try await withThrowingTaskGroup(of: FrozenSnapshot.self) { group in
            for (box, display, frame) in jobs {
                group.addTask {
                    let scale = display.backingScaleFactor
                    let image = try await Self.shoot(
                        box.filter, sourceRect: nil,
                        width: Int(CapturePlan.pixels(frame.width, scale)),
                        height: Int(CapturePlan.pixels(frame.height, scale)),
                        showsCursor: false
                    )
                    return FrozenSnapshot(image: image, displayID: display.id, displayFrame: frame, scale: scale)
                }
            }
            var snapshots: [FrozenSnapshot] = []
            for try await snapshot in group { snapshots.append(snapshot) }
            let order = layout.displays.map(\.id)
            return snapshots.sorted { (order.firstIndex(of: $0.displayID) ?? 0) < (order.firstIndex(of: $1.displayID) ?? 0) }
        }
    }

    // MARK: Helpers

    private func checkPermission() throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }
    }

    /// Cached content, refetched if it doesn't list our own app yet (so the
    /// exclusion filter can name it).
    private func resolvedContent() async throws -> SCShareableContent {
        let content = try await contentCache.content()
        if content.applications.contains(where: { $0.processID == ownPID }) {
            return content
        }
        return try await contentCache.content(forceRefresh: true)
    }

    private func makeFilter(displayID: CGDirectDisplayID, content: SCShareableContent) throws -> SCContentFilter {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        let ownApps = content.applications.filter { $0.processID == ownPID }
        if !ownApps.isEmpty {
            if hidesDesktopIcons {
                return SCContentFilter(
                    display: display,
                    excludingApplications: ownApps + DesktopIconFilter.ownerApplications(in: content),
                    exceptingWindows: DesktopIconFilter.keptWindows(from: content)
                )
            }
            return SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }
        // Fallback: our app isn't listed (no windows on screen); exclude any
        // of our windows that are.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let iconWindows = hidesDesktopIcons ? DesktopIconFilter.excludedWindows(from: content) : []
        return SCContentFilter(display: display, excludingWindows: ownWindows + iconWindows)
    }

    private func logSize(_ image: CGImage, expectedWidth: Int, expectedHeight: Int) {
        if image.width != expectedWidth || image.height != expectedHeight {
            Log.capture.warning("captured \(image.width)x\(image.height), expected \(expectedWidth)x\(expectedHeight)")
        } else {
            Log.capture.debug("captured \(image.width)x\(image.height)")
        }
    }

    /// One ScreenCaptureKit still. `sourceRect` is in the display's local
    /// points; `width`/`height` are the output pixels (points × scale).
    private static func shoot(
        _ filter: SCContentFilter, sourceRect: CGRect?, width: Int, height: Int, showsCursor: Bool
    ) async throws -> CGImage {
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        if let sourceRect { config.sourceRect = sourceRect }
        config.showsCursor = showsCursor
        config.captureResolution = .best
        config.scalesToFit = false
        let box = FilterBox(filter: filter)
        let configBox = ConfigBox(config: config)
        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: box.filter, configuration: configBox.config) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: CaptureError.captureFailed(error?.localizedDescription ?? "no image"))
                }
            }
        }
    }

    /// Draws `parts` into one transparent image; destinations are pixels,
    /// top-left origin.
    private static func composite(_ parts: [(CGImage, CGRect)], width: Int, height: Int) throws -> CGImage {
        let colorSpace = parts.first?.0.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)
        guard let colorSpace,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              )
        else { throw CaptureError.compositingFailed }
        context.interpolationQuality = .high
        for (image, destination) in parts {
            // CGContext is bottom-left origin (pixel space, not global coords).
            let rect = CGRect(
                x: destination.minX, y: CGFloat(height) - destination.maxY,
                width: destination.width, height: destination.height
            )
            context.draw(image, in: rect)
        }
        guard let result = context.makeImage() else { throw CaptureError.compositingFailed }
        return result
    }
}

/// `SCContentFilter`/`SCStreamConfiguration` aren't `Sendable`; they're
/// created, handed to ScreenCaptureKit once and never mutated afterwards.
private nonisolated struct FilterBox: @unchecked Sendable {
    let filter: SCContentFilter
}

private nonisolated struct ConfigBox: @unchecked Sendable {
    let config: SCStreamConfiguration
}
