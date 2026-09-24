import AppKit
import HakoKit
import SwiftUI

/// Top bar (plan §4.16, mirrors the screenshot editor's bar): traffic lights
/// → [Crop | Resize | Audio | Quality] capsule → output summary → Copy,
/// "Save as…" (gray) and "Done" (blue). Resize, Audio and Quality (format,
/// fps, quality, codec, GIF options) open popovers. In crop mode the bar
/// shows the crop controls instead.
struct VideoEditorToolbar: View {
    let model: VideoEditorViewModel
    let onCopy: () -> Void
    let onSaveAs: () -> Void
    let onDone: () -> Void

    @State private var showsResize = false
    @State private var showsAudio = false
    @State private var showsQuality = false

    var body: some View {
        HStack(spacing: EditorMetrics.toolbarGroupSpacing) {
            toolGroup
            ToolbarDivider()
            if model.isCropping {
                VideoCropBar(model: model)
                Spacer(minLength: 0)
                HStack(spacing: Tokens.Spacing.s) {
                    PillButton("Reset", style: .neutral) { model.resetCrop() }
                        .disabled(!model.hasCrop)
                        .help("Show the whole frame")
                    PillButton("Done", style: .primary) { model.setCropping(false) }
                        .help("Apply the crop (Return)")
                }
                .fixedSize()
            } else {
                Text(verbatim: summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                HStack(spacing: Tokens.Spacing.s) {
                    EditorToolButton(symbol: "doc.on.doc", help: "Copy (⌘C)", isEnabled: !model.isExporting, action: onCopy)
                    PillButton("Save as…", style: .neutral, action: onSaveAs)
                        .help("Save As… (⇧⌘S)")
                    PillButton("Done", style: .primary, action: onDone)
                        .help("Save and close")
                }
                .fixedSize()
                .disabled(model.isExporting || model.loadState != .ready)
            }
        }
        .padding(.leading, EditorMetrics.toolbarLeadingInset)
        .padding(.trailing, EditorMetrics.toolbarTrailingInset)
        .frame(maxWidth: .infinity, minHeight: VideoEditorMetrics.toolbarHeight, maxHeight: VideoEditorMetrics.toolbarHeight)
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
        }
        .allowsWindowActivationEvents(true)
        .ignoresSafeArea()
    }

    /// "1920 × 1080 · 60 fps · MP4 · 0:05.0".
    private var summary: String {
        guard model.loadState == .ready else { return "" }
        let size = model.outputPixelSize
        let fps = model.recipe.format == .gif
            ? model.recipe.gif.fps
            : model.recipe.outputFPS(sourceFPS: model.frameRate)
        return "\(size.width) × \(size.height) · \(fps) fps · \(model.recipe.format.rawValue.uppercased()) · \(VideoEditorTimeFormat.string(model.outputDuration))"
    }

    private var toolGroup: some View {
        let ready = model.loadState == .ready && !model.isExporting
        return HStack(spacing: 0) {
            EditorToolButton(symbol: "crop", help: "Crop", isActive: model.isCropping, isEnabled: ready) {
                model.toggleCropMode()
            }
            EditorToolButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Resize", isActive: showsResize, isEnabled: ready) {
                showsResize.toggle()
            }
            .popover(isPresented: $showsResize, arrowEdge: .bottom) { ResizePopover(model: model) }
            EditorToolButton(
                symbol: model.recipe.audio.muted ? "speaker.slash" : "speaker.wave.2",
                help: "Audio",
                isActive: showsAudio,
                isEnabled: ready
            ) {
                showsAudio.toggle()
            }
            .popover(isPresented: $showsAudio, arrowEdge: .bottom) { AudioPopover(model: model) }
            EditorToolButton(symbol: "slider.horizontal.3", help: "Quality, frame rate and format", isActive: showsQuality, isEnabled: ready) {
                showsQuality.toggle()
            }
            .popover(isPresented: $showsQuality, arrowEdge: .bottom) { QualityPopover(model: model) }
        }
        .padding(.horizontal, Tokens.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.neutralPillFill)))
        .fixedSize()
        .layoutPriority(2)
    }
}

// MARK: - Popovers

private struct PopoverSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            content
        }
    }
}

/// Resize: presets (short edge, no upscaling) or a custom width / height
/// with the aspect ratio locked.
struct ResizePopover: View {
    let model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            PopoverSection(title: "Resize") {
                Picker("Size", selection: Binding(
                    get: { model.resizePreset },
                    set: { if let preset = $0 { model.applyResizePreset(preset) } }
                )) {
                    ForEach(model.availableResizePresets) { preset in
                        Text(preset.label).tag(Optional(preset))
                    }
                    if model.resizePreset == nil {
                        Text("Custom").tag(VideoResizePreset?.none)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            PopoverSection(title: "Custom size (aspect ratio locked)") {
                let size = model.outputPixelSize
                HStack(spacing: Tokens.Spacing.xs) {
                    VideoEditorNumberField(value: size.width, help: "Width (px)") { model.setOutputWidth($0) }
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                    VideoEditorNumberField(value: size.height, help: "Height (px)") { model.setOutputHeight($0) }
                    Text("px")
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
                .disabled(model.recipe.format == .gif)
                if model.recipe.format == .gif {
                    Text("GIF size is set under Quality.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 240)
    }
}

/// Audio: mute, volume 0–200 %, mono, per-track levels for two tracks.
struct AudioPopover: View {
    let model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if model.audioTrackCount == 0 {
                Text("This video has no audio.")
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            } else {
                Toggle("Mute", isOn: Binding(get: { model.recipe.audio.muted }, set: { model.setMuted($0) }))
                PopoverSection(title: "Volume") {
                    gainSlider(value: model.recipe.audio.volume, track: nil)
                }
                .disabled(model.recipe.audio.muted)
                Toggle("Mono", isOn: Binding(get: { model.recipe.audio.mono }, set: { model.setMono($0) }))
                    .disabled(model.recipe.audio.muted)
                if model.audioTrackCount > 1 {
                    PopoverSection(title: "Tracks") {
                        ForEach(0..<model.audioTrackCount, id: \.self) { index in
                            HStack {
                                Text(verbatim: "Track \(index + 1)").frame(width: 56, alignment: .leading)
                                gainSlider(value: model.trackGain(index), track: index)
                            }
                        }
                    }
                    .disabled(model.recipe.audio.muted)
                }
            }
        }
        .toggleStyle(.checkbox)
        .padding(Tokens.Spacing.l)
        .frame(width: 260)
    }

    /// `track` `nil`: the master volume; else that audio track's gain.
    private func gainSlider(value: Double, track: Int?) -> some View {
        let binding = Binding(
            get: { value },
            set: { newValue in
                if let track { model.setTrackGain(track, newValue) } else { model.setVolume(newValue) }
            }
        )
        return HStack(spacing: Tokens.Spacing.s) {
            Slider(value: binding, in: 0...VideoEditAudio.maxGain) { editing in
                editing ? model.beginInteraction() : model.endInteraction()
            }
            Text(verbatim: "\(Int((value * 100).rounded())) %")
                .font(.system(size: 11).monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }
}

/// Quality: format MP4 / GIF; for MP4 the fps (original and lower),
/// quality and codec; for GIF the GIF fps, width, quality and optimize.
struct QualityPopover: View {
    let model: VideoEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Picker("Format", selection: Binding(get: { model.recipe.format }, set: { model.setFormat($0) })) {
                Text("MP4").tag(VideoEditOutputFormat.mp4)
                Text("GIF").tag(VideoEditOutputFormat.gif)
            }
            .pickerStyle(.segmented)

            if model.recipe.format == .mp4 {
                Picker("Frame rate", selection: Binding(get: { model.recipe.fps }, set: { model.setFPS($0) })) {
                    Text(verbatim: "Original (\(Int(model.frameRate.rounded())) fps)").tag(Int?.none)
                    ForEach(model.availableFrameRates, id: \.self) { fps in
                        Text(verbatim: "\(fps) fps").tag(Optional(fps))
                    }
                }
                Picker("Quality", selection: Binding(get: { model.recipe.quality }, set: { model.setQuality($0) })) {
                    ForEach(VideoQuality.allCases, id: \.self) { quality in
                        Text(quality.rawValue.capitalized).tag(quality)
                    }
                }
                Picker("Codec", selection: Binding(get: { model.recipe.codec }, set: { model.setCodec($0) })) {
                    Text("H.264").tag(VideoCodec.h264)
                    Text("HEVC").tag(VideoCodec.hevc)
                }
            } else {
                Picker("Frame rate", selection: Binding(get: { model.recipe.gif.fps }, set: { model.setGIFFPS($0) })) {
                    ForEach(RecordingSettingChoices.gifFrameRates, id: \.self) { fps in
                        Text(verbatim: "\(fps) fps").tag(fps)
                    }
                }
                Picker("Width", selection: Binding(get: { model.recipe.gif.width }, set: { model.setGIFWidth($0) })) {
                    ForEach(RecordingSettingChoices.gifWidths, id: \.self) { width in
                        Text(verbatim: width == RecordingSettingChoices.gifOriginalWidth ? "Original" : "\(width) px").tag(width)
                    }
                }
                HStack(spacing: Tokens.Spacing.s) {
                    Text("Quality")
                    Slider(value: Binding(get: { model.recipe.gif.quality }, set: { model.setGIFQuality($0) }), in: 0...1) { editing in
                        editing ? model.beginInteraction() : model.endInteraction()
                    }
                }
                Toggle("Optimize GIF", isOn: Binding(get: { model.recipe.gif.optimize }, set: { model.setGIFOptimize($0) }))
                    .toggleStyle(.checkbox)
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 280)
    }
}
