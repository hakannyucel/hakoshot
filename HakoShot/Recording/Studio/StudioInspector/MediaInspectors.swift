import HakoKit
import SwiftUI

/// Motion blur tab (plan §4.19): on/off and intensity (shutter 180° × intensity).
struct MotionBlurInspector: View {
    let model: StudioViewModel

    private var blur: StudioMotionBlur { model.project.motionBlur }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            InspectorToggle(title: "Motion blur", isOn: blur.enabled) { on in
                model.apply(.setMotionBlur(StudioMotionBlur(enabled: on, intensity: blur.intensity)))
            }
            InspectorSlider(model: model, title: "Intensity", value: blur.intensity, range: 0...1, step: 0.01,
                            format: InspectorFormat.percent) { v in
                model.apply(.setMotionBlur(StudioMotionBlur(enabled: blur.enabled, intensity: v)))
            }
            .disabled(!blur.enabled)
            InspectorNote(text: "Blurs zoom, pan and cursor movement. The preview uses a lighter blur while playing; the export uses full quality.")
        }
    }
}

/// Camera tab (plan §4.18): only for projects recorded with a webcam.
struct CameraInspector: View {
    let model: StudioViewModel

    private var camera: StudioCameraSettings { model.project.camera }

    var body: some View {
        if model.project.source.hasCamera {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                InspectorToggle(title: "Show camera", isOn: camera.visible) { v in update { $0.visible = v } }
                Group {
                    Picker("Shape", selection: Binding(get: { camera.shape }, set: { v in update { $0.shape = v } })) {
                        Text("Squircle").tag(StudioCameraShape.squircle)
                        Text("Circle").tag(StudioCameraShape.circle)
                        Text("16:9").tag(StudioCameraShape.rectangle)
                        Text("9:16").tag(StudioCameraShape.vertical)
                    }
                    InspectorSlider(model: model, title: "Size", value: camera.size, range: StudioCameraSettings.sizeRange, step: 0.01,
                                    format: InspectorFormat.percent) { v in update { $0.size = v } }
                    Picker("Corner", selection: Binding(get: { camera.corner }, set: { v in update { $0.corner = v } })) {
                        Text("Top left").tag(StudioCameraCorner.topLeft)
                        Text("Top right").tag(StudioCameraCorner.topRight)
                        Text("Bottom left").tag(StudioCameraCorner.bottomLeft)
                        Text("Bottom right").tag(StudioCameraCorner.bottomRight)
                    }
                    InspectorToggle(title: "Mirror", isOn: camera.mirrored) { v in update { $0.mirrored = v } }
                    InspectorToggle(title: "Shadow", isOn: camera.shadow) { v in update { $0.shadow = v } }
                    InspectorToggle(title: "White border", isOn: camera.border) { v in update { $0.border = v } }
                }
                .font(.system(size: 12))
                .disabled(!camera.visible)
            }
        } else {
            InspectorNote(text: "This recording has no camera video. Turn on the camera in the recording options before recording in Studio Mode.")
        }
    }

    /// One `.setCamera` with `change` applied.
    private func update(_ change: (inout StudioCameraSettings) -> Void) {
        var c = camera
        change(&c)
        model.apply(.setCamera(c))
    }
}

/// Audio tab: mute, master volume, mono, per-track volume.
struct AudioInspector: View {
    let model: StudioViewModel

    private var audio: VideoEditAudio { model.project.audio }
    private var tracks: [String] { model.project.source.audioTracks }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            if tracks.isEmpty {
                InspectorNote(text: "This recording has no audio.")
            }
            InspectorToggle(title: "Mute", isOn: audio.muted) { on in
                var a = audio
                a.muted = on
                model.apply(.setAudio(a))
            }
            InspectorSlider(model: model, title: "Volume", value: audio.volume, range: 0...VideoEditAudio.maxGain, step: 0.01,
                            format: InspectorFormat.percent) { v in
                var a = audio
                a.volume = v
                model.apply(.setAudio(a))
            }
            .disabled(audio.muted)
            if tracks.count > 1 {
                ForEach(tracks.indices, id: \.self) { i in
                    InspectorSlider(model: model, title: tracks[i].capitalized, value: trackGain(i), range: 0...VideoEditAudio.maxGain,
                                    step: 0.01, format: InspectorFormat.percent) { v in
                        var a = audio
                        while a.trackGains.count < tracks.count { a.trackGains.append(1) }
                        a.trackGains[i] = v
                        model.apply(.setAudio(a))
                    }
                    .disabled(audio.muted)
                }
            }
            InspectorToggle(title: "Mono", isOn: audio.mono) { on in
                var a = audio
                a.mono = on
                model.apply(.setAudio(a))
            }
            .disabled(audio.muted)
        }
        .disabled(tracks.isEmpty && !audio.muted)
    }

    private func trackGain(_ i: Int) -> Double {
        audio.trackGains.indices.contains(i) ? audio.trackGains[i] : 1
    }
}
