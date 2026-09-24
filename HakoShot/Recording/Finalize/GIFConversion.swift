import AppKit
import AVFoundation
import HakoKit
import ImageIO
import os
import SwiftUI

/// Video → GIF for recordings (kayit-teknik-plan §4.14, §4.17): Record GIF
/// (finalize converts the silent mp4), Quick Access ⌘G / "Convert to GIF",
/// History "Convert to GIF" and `hakoshot://convert-to-gif`. The frames come
/// from `GIFExportJob` with Settings › Screen Recording › GIF; the result is a
/// `RecordingResult` with format `.gif` that goes through
/// `RecordingOutputRouter` like any recording.
nonisolated enum GIFConversion {
    /// After-recording actions for a converted file (Quick Access ⌘G, History,
    /// URL): a new GIF card (+ History, always); never the video editor.
    static let deliveryConfig = AfterRecordingConfig(showQuickAccess: true, copyToClipboard: false, saveToDisk: false, openVideoEditor: false)

    /// Settings › Screen Recording › GIF (`gifFrameRate`, `gifWidth`, `gifOptimize`, `gifQuality`).
    @MainActor
    static func options(settings: AppSettings) -> GIFExportOptions {
        GIFExportOptions(
            fps: settings.value(for: .gifFrameRate),
            width: settings.value(for: .gifWidth),
            optimize: settings.value(for: .gifOptimize),
            quality: settings.value(for: .gifQuality)
        ).normalized()
    }

    // MARK: Size estimate (plan §4.17: > 50 MB → "This GIF will be large")

    static func estimatedBytes(duration: Double, pixelWidth: Int, pixelHeight: Int, options: GIFExportOptions) -> Int {
        let size = options.outputSize(sourceWidth: pixelWidth, sourceHeight: pixelHeight)
        return GIFFrameSampler.estimatedByteCount(
            width: size.width, height: size.height, duration: max(0, duration), fps: options.fps, optimize: options.optimize
        )
    }

    static func isLarge(_ bytes: Int) -> Bool {
        bytes > GIFFrameSampler.largeGIFWarningBytes
    }

    /// `nil` when the file can't be read (the conversion reports the error).
    static func estimatedBytes(for source: URL, options: GIFExportOptions) async -> Int? {
        guard let info = try? await RenderPipeline.probe(source) else { return nil }
        return estimatedBytes(duration: info.duration, pixelWidth: info.pixelWidth, pixelHeight: info.pixelHeight, options: options)
    }

    // MARK: Converting

    /// Where Quick Access / History / URL conversions write the GIF: the
    /// retained-recordings folder (History copies it; History off → the
    /// card keeps using it; purged after 7 days).
    static func newWorkFileURL(in folder: URL = RecordingOutputRouter.defaultRetainedFolder) -> URL {
        folder.appending(path: "\(UUID().uuidString).gif")
    }

    /// Writes the GIF for `source` to `destination` and describes it. Throws
    /// `CancellationError` when cancelled (no file left behind).
    static func convert(
        source: URL,
        options: GIFExportOptions,
        to destination: URL,
        targetKind: RecordingTargetKind = .area,
        date: Date = .now,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> RecordingResult {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let url = try await GIFExportJob.export(source: source, options: options, to: destination, progress: progress)
        return try result(forGIF: url, targetKind: targetKind, date: date)
    }

    enum GIFReadError: Error, CustomStringConvertible {
        case unreadable(URL)
        var description: String {
            switch self {
            case let .unreadable(url): "unreadable GIF \(url.lastPathComponent)"
            }
        }
    }

    /// Size, duration (sum of the frame delays) and poster of a GIF file.
    static func result(forGIF url: URL, targetKind: RecordingTargetKind = .area, date: Date = .now) throws -> RecordingResult {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw GIFReadError.unreadable(url) }
        var duration = 0.0
        for index in 0..<CGImageSourceGetCount(source) {
            let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0
            duration += delay
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(RecordingThumbnailer.maxDimension),
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw GIFReadError.unreadable(url) }
        return RecordingResult(
            fileURL: url,
            format: .gif,
            duration: duration,
            pixelSize: CGSize(width: width, height: height),
            thumbnail: thumbnail,
            date: date,
            targetKind: targetKind
        )
    }
}

// MARK: - UI

/// "This GIF will be large" (plan §4.17).
@MainActor
enum GIFConversionPrompt {
    /// `true` = go ahead.
    static func confirmLarge(bytes: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "This GIF will be large"
        let megabytes = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        alert.informativeText = "It could be about \(megabytes). A lower frame rate or width in Settings › Screen Recording › GIF makes it smaller."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Forwards progress reported on any thread to the main actor and drops
/// updates that arrive after `finish()`.
@MainActor
final class GIFProgressRelay {
    private let handler: (Double) -> Void
    private var finished = false
    private var last = -1.0

    init(_ handler: @escaping (Double) -> Void) {
        self.handler = handler
    }

    nonisolated var report: @Sendable (Double) -> Void {
        { [weak self] value in
            Task { @MainActor in self?.deliver(value) }
        }
    }

    private func deliver(_ value: Double) {
        guard !finished, value - last >= 0.01 || value >= 1 else { return }
        last = value
        handler(min(max(value, 0), 1))
    }

    func finish() {
        finished = true
    }
}

/// Small progress panel for conversions without a Quick Access card to show
/// progress on (Record GIF, History, URL): "Converting to GIF… 42 %" with a
/// Cancel button; Esc cancels too (changelog 2.7 "progress indicator",
/// plan §4.14: cancelling a Record GIF keeps the video).
@MainActor
final class GIFProgressHUD {
    @Observable
    final class Model {
        var progress = 0.0
        var onCancel: () -> Void = {}
    }

    private enum Metrics {
        static let barWidth: CGFloat = 180
        static let bottomInset: CGFloat = 96
    }

    private let model = Model()
    private var panel: NSPanel?
    private var localMonitor: Any?
    private var globalMonitor: Any?

    var isVisible: Bool { panel != nil }

    func show(onCancel: @escaping () -> Void) {
        model.onCancel = onCancel
        let hosting = NSHostingView(rootView: GIFProgressView(model: model))
        let size = hosting.fittingSize
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + Metrics.bottomInset))
        }
        panel.orderFrontRegardless()
        self.panel = panel

        let escape: UInt16 = 53
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == escape else { return event }
            self?.model.onCancel()
            return nil
        }
        // Needs Accessibility; without it only the Cancel button works.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == escape else { return }
            MainActor.assumeIsolated { self?.model.onCancel() }
        }
    }

    func update(_ progress: Double) {
        model.progress = progress
    }

    func close() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private struct GIFProgressView: View {
        let model: Model

        var body: some View {
            HStack(spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    HStack {
                        Text("Converting to GIF…")
                        Spacer(minLength: Tokens.Spacing.s)
                        Text(model.progress, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
                    }
                    .font(Tokens.Typography.pillLabel)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(width: Metrics.barWidth)
                }
                Button("Cancel") { model.onCancel() }
                    .controlSize(.small)
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .fixedSize()
            .environment(\.colorScheme, .dark)
            .hudPanel(cornerRadius: Tokens.Radius.toastBadge, blendingMode: .behindWindow, shadow: .toast)
        }
    }
}
