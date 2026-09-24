import AVFoundation
import HakoKit
import SwiftUI

/// Crop rectangle over the (uncropped) preview while crop mode is on
/// (plan §4.16: same behavior as the screenshot editor's crop: aspect menu,
/// W × H, rule-of-thirds lines). Works in source pixels through `CropMath`;
/// drag a handle to resize, inside to move, outside to draw a new rect.
struct VideoCropOverlay: View {
    let model: VideoEditorViewModel
    @State private var drag: DragKind?

    private enum DragKind {
        case resize(CropHandle)
        case move(start: CGRect)
        case draw(anchor: CGPoint)
    }

    var body: some View {
        GeometryReader { proxy in
            let content = CGRect(origin: .zero, size: proxy.size)
                .insetBy(dx: VideoEditorMetrics.playerInset, dy: VideoEditorMetrics.playerInset)
            let video = PlayerView.fittedRect(for: model.sourcePixelSize, in: content)
            let scale = model.sourcePixelSize.width > 0 ? video.width / model.sourcePixelSize.width : 1
            let crop = viewRect(model.cropRect, video: video, scale: scale)
            ZStack(alignment: .topLeading) {
                // Dim outside the crop, inside the video.
                Path { path in
                    path.addRect(video)
                    path.addRect(crop)
                }
                .fill(Color(nsColor: Tokens.Palette.cropDim), style: FillStyle(eoFill: true))

                thirds(crop)
                    .stroke(Color.white.opacity(Tokens.Editor.cropGuideOpacity), lineWidth: Tokens.Stroke.hairline)
                Rectangle()
                    .path(in: crop)
                    .stroke(Color.white, lineWidth: Tokens.Stroke.hairline)
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    let p = handle.position(in: crop)
                    let size = VideoEditorMetrics.cropHandleSize
                    Rectangle()
                        .fill(Color.white)
                        .overlay(Rectangle().stroke(Color.black.opacity(0.35), lineWidth: Tokens.Stroke.hairline))
                        .frame(width: size, height: size)
                        .position(p)
                }
                sizeLabel(for: crop)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(dragGesture(video: video, scale: scale))
        }
    }

    private func viewRect(_ pixels: CGRect, video: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: video.minX + pixels.minX * scale, y: video.minY + pixels.minY * scale,
               width: pixels.width * scale, height: pixels.height * scale)
    }

    private func pixelPoint(_ point: CGPoint, video: CGRect, scale: CGFloat) -> CGPoint {
        CGPoint(x: (point.x - video.minX) / scale, y: (point.y - video.minY) / scale)
    }

    private func thirds(_ rect: CGRect) -> Path {
        Path { path in
            for i in 1...2 {
                let x = rect.minX + rect.width * CGFloat(i) / 3
                let y = rect.minY + rect.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: rect.maxY))
                path.move(to: CGPoint(x: rect.minX, y: y))
                path.addLine(to: CGPoint(x: rect.maxX, y: y))
            }
        }
    }

    private func sizeLabel(for crop: CGRect) -> some View {
        let pixels = model.cropRect
        return Text(verbatim: "\(Int(pixels.width)) × \(Int(pixels.height))")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, Tokens.Spacing.s)
            .padding(.vertical, Tokens.Spacing.xxs)
            .background(Capsule().fill(Color(nsColor: Tokens.Palette.hudControlFill)))
            .fixedSize()
            .position(x: crop.midX, y: max(crop.minY - 14, 12))
            .allowsHitTesting(false)
    }

    private func dragGesture(video: CGRect, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                let point = pixelPoint(value.location, video: video, scale: scale)
                let bounds = model.cropBounds
                let ratio = model.cropAspect.value(original: model.sourcePixelSize)
                if drag == nil {
                    let start = pixelPoint(value.startLocation, video: video, scale: scale)
                    let tolerance = VideoEditorMetrics.cropHandleHitDistance / max(scale, 0.0001)
                    if let handle = CropMath.handle(at: start, of: model.cropRect, tolerance: tolerance) {
                        drag = .resize(handle)
                    } else if model.cropRect.contains(start) {
                        drag = .move(start: model.cropRect)
                    } else {
                        let clamped = CGPoint(x: min(max(start.x, 0), bounds.maxX), y: min(max(start.y, 0), bounds.maxY))
                        drag = .draw(anchor: clamped)
                    }
                    model.beginInteraction()
                }
                switch drag {
                case .resize(let handle):
                    model.setCropRect(CropMath.resize(model.cropRect, handle: handle, to: point, ratio: ratio, bounds: bounds))
                case .move(let start):
                    let delta = CGVector(dx: value.translation.width / scale, dy: value.translation.height / scale)
                    model.setCropRect(CropMath.move(start, by: delta, bounds: bounds))
                case .draw(let anchor):
                    let handle = CropHandle.corner(from: anchor, to: point)
                    let seed = CGRect(origin: anchor, size: .zero)
                    model.setCropRect(CropMath.resize(seed, handle: handle, to: point, ratio: ratio, bounds: bounds))
                case nil:
                    break
                }
            }
            .onEnded { _ in
                drag = nil
                model.endInteraction()
            }
    }
}

/// Crop mode's controls in the toolbar: aspect menu, W × H, Reset, Done.
struct VideoCropBar: View {
    let model: VideoEditorViewModel

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Menu {
                ForEach(CropAspect.menu, id: \.self) { aspect in
                    Button {
                        model.setCropAspect(aspect)
                    } label: {
                        if aspect == model.cropAspect { Label(aspect.label, systemImage: "checkmark") } else { Text(aspect.label) }
                    }
                    if aspect == .original { Divider() }
                }
            } label: {
                Text(model.cropAspect.label)
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Aspect ratio")

            HStack(spacing: Tokens.Spacing.xs) {
                VideoEditorNumberField(value: Int(model.cropRect.width), help: "Width (px)") { width in
                    let ratio = model.cropAspect.value(original: model.sourcePixelSize)
                    let height = ratio.map { Int(CropMath.linked(width: CGFloat(width), ratio: $0)) } ?? Int(model.cropRect.height)
                    model.setCropSize(width: width, height: height)
                }
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                VideoEditorNumberField(value: Int(model.cropRect.height), help: "Height (px)") { height in
                    let ratio = model.cropAspect.value(original: model.sourcePixelSize)
                    let width = ratio.map { Int(CropMath.linked(height: CGFloat(height), ratio: $0)) } ?? Int(model.cropRect.width)
                    model.setCropSize(width: width, height: height)
                }
            }

            Text(verbatim: "Video: \(Int(model.sourcePixelSize.width)) × \(Int(model.sourcePixelSize.height)) px")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                .lineLimit(1)
                .layoutPriority(-1)
        }
    }
}

/// Small numeric text field that commits on Return / focus loss.
struct VideoEditorNumberField: View {
    let value: Int
    let help: String
    var width: CGFloat = 58
    let commit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .font(.system(size: 12))
            .frame(width: width)
            .focused($focused)
            .help(help)
            .onAppear { text = String(value) }
            .onChange(of: value) { _, new in if !focused { text = String(new) } }
            .onChange(of: focused) { _, isFocused in if !isFocused { submit() } }
            .onSubmit(submit)
    }

    private func submit() {
        if let number = Int(text.trimmingCharacters(in: .whitespaces)), number > 0, number != value {
            commit(number)
        } else {
            text = String(value)
        }
    }
}
