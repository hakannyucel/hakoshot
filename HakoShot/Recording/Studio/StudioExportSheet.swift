import AppKit
import AVFoundation
import HakoKit
import ImageIO
import Observation
import os
import SwiftUI

/// Export sheet state (plan §4.19): presets (aspect ratio + resolution +
/// frame rate), format MP4 / GIF, resolution (canvas `outputHeight`), frame
/// rate, quality (MP4) or width / fps / quality (GIF); progress and cancel. The file goes to the export location with
/// the file-name template; the choices are stored in the project.
@MainActor
@Observable
final class StudioExportModel {
    enum Phase: Equatable {
        case idle
        case exporting(Double)
        case failed(String)
    }

    /// One-click export setups (plan §6 R7: 9:16 / 1:1 presets).
    struct Preset: Identifiable, Equatable {
        let title: String
        let aspectRatio: RecordingAspectRatio
        let outputHeight: Int
        let fps: Int
        var id: String { title }

        static let all: [Preset] = [
            Preset(title: "4K", aspectRatio: .sixteenNine, outputHeight: 2160, fps: 60),
            Preset(title: "1080p", aspectRatio: .sixteenNine, outputHeight: 1080, fps: 60),
            Preset(title: "9:16", aspectRatio: .nineSixteen, outputHeight: 1920, fps: 30),
            Preset(title: "1:1", aspectRatio: .square, outputHeight: 1080, fps: 30),
        ]
    }

    let studio: StudioViewModel
    var format: VideoEditOutputFormat
    /// Canvas aspect ratio (the Background tab's setting; presets change it).
    var aspectRatio: RecordingAspectRatio
    var outputHeight: Int
    var fps: Int
    var quality: VideoQuality
    var gifWidth: Int
    var gifFPS: Int
    var gifQuality: Double
    private(set) var phase: Phase = .idle
    /// `nil` = cancelled / closed.
    @ObservationIgnored var onFinished: ((RecordingResult?) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let settings: AppSettings

    init(studio: StudioViewModel, settings: AppSettings = .shared) {
        self.studio = studio
        self.settings = settings
        let p = studio.project
        format = p.export.format
        aspectRatio = p.canvas.aspectRatio
        outputHeight = p.canvas.outputHeight
        fps = p.export.fps
        quality = p.export.quality
        gifWidth = p.export.gif.width
        gifFPS = p.export.gif.fps
        gifQuality = p.export.gif.quality
    }

    var isExporting: Bool { if case .exporting = phase { true } else { false } }

    /// Output heights offered: the standard ones plus the current value
    /// (e.g. 1920 from the 9:16 preset).
    var outputHeightChoices: [Int] {
        Array(Set(StudioCanvas.outputHeights + [outputHeight])).sorted()
    }

    /// The preset matching the current choices, if any.
    var selectedPreset: Preset? {
        Preset.all.first { $0.aspectRatio == aspectRatio && $0.outputHeight == outputHeight && $0.fps == fps }
    }

    /// MP4 with the preset's ratio, height and frame rate.
    func apply(_ preset: Preset) {
        format = .mp4
        aspectRatio = preset.aspectRatio
        outputHeight = preset.outputHeight
        fps = preset.fps
    }

    /// Output pixel size for the current choices.
    var outputSize: CGSize {
        var p = studio.project
        p.canvas.aspectRatio = aspectRatio
        p.canvas.outputHeight = outputHeight
        let canvas = p.canvasPixelSize
        guard format == .gif else { return canvas }
        let size = GIFExportOptions(fps: gifFPS, width: gifWidth, quality: gifQuality)
            .outputSize(sourceWidth: Int(canvas.width), sourceHeight: Int(canvas.height))
        return CGSize(width: size.width, height: size.height)
    }

    /// Writes the choices into the project (one undo step).
    private func storeChoices() {
        var export = studio.project.export
        export.format = format
        export.fps = fps
        export.quality = quality
        export.gif.width = gifWidth
        export.gif.fps = gifFPS
        export.gif.quality = gifQuality
        studio.beginInteraction("Export Settings")
        studio.apply(.setExport(export))
        if studio.project.canvas.aspectRatio != aspectRatio { studio.apply(.setAspectRatio(aspectRatio)) }
        studio.apply(.setOutputHeight(outputHeight))
        studio.endInteraction()
    }

    func start() {
        guard !isExporting else { return }
        storeChoices()
        let project = studio.project
        let media = studio.media
        let date = Date()
        let destination = Self.destination(format: project.export.format, date: date, settings: settings)
        phase = .exporting(0)
        let update: @Sendable (Double) -> Void = { value in
            Task { @MainActor [weak self] in self?.setProgress(value) }
        }
        task = Task { [weak self] in
            do {
                let url = try await StudioExport.export(project: project, media: media, to: destination, progress: update)
                let result = try await Self.result(for: url, project: project, date: date)
                self?.phase = .idle
                StudioViewModel.log.notice("studio export saved \(url.path, privacy: .public)")
                self?.onFinished?(result)
            } catch is CancellationError {
                self?.phase = .idle
            } catch {
                self?.phase = .failed(String(describing: error))
            }
        }
    }

    private func setProgress(_ value: Double) {
        guard case .exporting = phase else { return }
        phase = .exporting(value)
    }

    func cancel() {
        if let task, isExporting {
            task.cancel()
            self.task = nil
            phase = .idle
        } else {
            onFinished?(nil)
        }
    }

    // MARK: Output

    /// Export folder + file-name template, `.mp4` / `.gif`, never overwrites.
    static func destination(format: VideoEditOutputFormat, date: Date, settings: AppSettings) -> URL {
        let folder = URL(fileURLWithPath: (settings.value(for: .outputSaveFolderPath) as NSString).expandingTildeInPath,
                         isDirectory: true)
        let pattern = settings.value(for: .outputFileNameTemplate)
        let counter = FileNameCounter.take(pattern: pattern, settings: settings)
        let namer = FileNamer(template: FileNameTemplate(pattern: pattern), pathExtension: format.fileExtension, clock: { date })
        return namer.resolvedURL(in: folder, counter: counter, mode: RecordingTargetKind.area.fileNameToken) {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    /// `RecordingResult` for the Quick Access card.
    static func result(for url: URL, project: StudioProject, date: Date) async throws -> RecordingResult {
        let isGIF = url.pathExtension.lowercased() == "gif"
        let duration = project.timeline.outputDuration
        let thumbnail: CGImage
        if isGIF {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw RenderError.cannotRead("GIF thumbnail")
            }
            thumbnail = image
        } else {
            thumbnail = try await RecordingThumbnailer.thumbnail(for: url, duration: duration)
        }
        var size = project.canvasPixelSize
        if isGIF { size = CGSize(width: thumbnail.width, height: thumbnail.height) }
        return RecordingResult(fileURL: url, format: isGIF ? .gif : .video, duration: duration, pixelSize: size,
                               thumbnail: thumbnail, date: date, targetKind: .area)
    }
}

/// The sheet (`StudioWindowController.showExportSheet`).
struct StudioExportSheet: View {
    @Bindable var model: StudioExportModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            Text("Export").font(.headline)
            HStack(spacing: Tokens.Spacing.s) {
                Text("Presets").font(.system(size: 12))
                ForEach(StudioExportModel.Preset.all) { preset in
                    Button(preset.title) { model.apply(preset) }
                        .buttonStyle(.bordered)
                        .tint(model.format == .mp4 && model.selectedPreset == preset ? .accentColor : nil)
                        .help("\(preset.aspectRatio.description), \(preset.outputHeight)p, \(preset.fps) fps")
                }
            }
            .controlSize(.small)
            .disabled(model.isExporting)
            Picker("Format", selection: $model.format) {
                Text("MP4").tag(VideoEditOutputFormat.mp4)
                Text("GIF").tag(VideoEditOutputFormat.gif)
            }
            .pickerStyle(.segmented)

            Form {
                if model.format == .mp4 {
                    Picker("Aspect ratio", selection: $model.aspectRatio) {
                        ForEach(RecordingAspectRatio.studioPresets, id: \.self) { ratio in
                            Text(ratio.isFreeform ? "Auto" : ratio.description).tag(ratio)
                        }
                    }
                    Picker("Resolution", selection: $model.outputHeight) {
                        ForEach(model.outputHeightChoices, id: \.self) { Text("\($0)p").tag($0) }
                    }
                    Picker("Frame rate", selection: $model.fps) {
                        ForEach(RecordingSettingChoices.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Quality", selection: $model.quality) {
                        Text("Low").tag(VideoQuality.low)
                        Text("Medium").tag(VideoQuality.medium)
                        Text("High").tag(VideoQuality.high)
                        Text("Ultra").tag(VideoQuality.ultra)
                    }
                } else {
                    Picker("Width", selection: $model.gifWidth) {
                        ForEach(RecordingSettingChoices.gifWidths, id: \.self) { w in
                            Text(w == 0 ? "Original" : "\(w) px").tag(w)
                        }
                    }
                    Picker("Frame rate", selection: $model.gifFPS) {
                        ForEach(RecordingSettingChoices.gifFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    LabeledContent("Quality") {
                        Slider(value: $model.gifQuality, in: 0...1)
                    }
                }
                LabeledContent("Size") {
                    Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height)) px, \(StudioTimeFormat.string(model.studio.timeline.outputDuration))")
                        .monospacedDigit()
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
            }
            .formStyle(.columns)
            .disabled(model.isExporting)

            switch model.phase {
            case .exporting(let value):
                ProgressView(value: value) {
                    Text("Exporting… \(Int((value * 100).rounded())) %").font(.system(size: 11))
                }
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.red)
                    .fixedSize(horizontal: false, vertical: true)
            case .idle:
                EmptyView()
            }

            HStack {
                Spacer()
                Button("Cancel") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Export") { model.start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isExporting)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: StudioLayout.exportSheetWidth)
    }
}
