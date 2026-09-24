import AppKit
import HakoKit
import SwiftUI

/// Bottom-bar "2000 × 1200 px" pill: opens the Resize Image / Canvas Size popover.
struct ImageSizeButton: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        let size = model.outputContentSize
        Button {
            model.showsSizePopover.toggle()
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Text(verbatim: "\(Int(size.width)) × \(Int(size.height)) px")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }
            .foregroundStyle(Color(nsColor: Tokens.Palette.textPrimary))
            .padding(.horizontal, Tokens.Spacing.m)
            .frame(height: Tokens.Size.pillHeight)
            .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.neutralPillFill)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Resize Image / Canvas Size")
        .popover(isPresented: $model.showsSizePopover, arrowEdge: .top) {
            ImageSizePopover(model: model)
        }
    }
}

/// Resize Image (scales everything, aspect lock) or Canvas Size (adds /
/// removes space around the content, 3×3 anchor). Apply = one undo step.
struct ImageSizePopover: View {
    enum Mode: String, CaseIterable, Identifiable {
        case resize = "Resize Image"
        case canvas = "Canvas Size"
        var id: String { rawValue }
    }

    let model: EditorViewModel
    @State private var mode: Mode = .resize
    @State private var width = 0
    @State private var height = 0
    @State private var keepsAspect = true
    @State private var anchor: BackgroundAlignment = .center

    private var original: CGSize { mode == .resize ? model.outputContentSize : model.displayedCanvasSize }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: Tokens.Spacing.s) {
                sizeField("Width", value: $width) { new in
                    if keepsAspect, original.width > 0 { height = max(Int((CGFloat(new) * original.height / original.width).rounded()), 1) }
                }
                Button {
                    keepsAspect.toggle()
                    if keepsAspect, original.width > 0 { height = max(Int((CGFloat(width) * original.height / original.width).rounded()), 1) }
                } label: {
                    Image(systemName: keepsAspect ? "lock" : "lock.open")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(keepsAspect ? Color.accentColor : Color(nsColor: Tokens.Palette.textSecondary))
                .help(keepsAspect ? "Aspect ratio locked" : "Aspect ratio unlocked")
                sizeField("Height", value: $height) { new in
                    if keepsAspect, original.height > 0 { width = max(Int((CGFloat(new) * original.width / original.height).rounded()), 1) }
                }
                Text("px").foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }

            if mode == .resize {
                HStack(spacing: Tokens.Spacing.xs) {
                    ForEach([25, 50, 75, 150, 200], id: \.self) { percent in
                        Button("\(percent)%") { applyPercent(percent) }
                            .controlSize(.small)
                    }
                }
                Text("Scales the screenshot, added images and annotations.")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            } else {
                HStack(alignment: .top, spacing: Tokens.Spacing.m) {
                    AlignmentGrid(selected: anchor) { anchor = $0 }
                    Text("Content position. New space is transparent; use Background to fill it.")
                        .font(Tokens.Typography.rowDescription)
                        .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: Tokens.Spacing.s) {
                Text(verbatim: "Now: \(Int(original.width)) × \(Int(original.height)) px")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                Spacer(minLength: Tokens.Spacing.s)
                PillButton("Cancel", style: .neutral) { model.showsSizePopover = false }
                PillButton("Apply", style: .primary, action: apply)
                    .disabled(width < 1 || height < 1 || (width == Int(original.width) && height == Int(original.height)))
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(width: 340)
        .onAppear(perform: reset)
        .onChange(of: mode) { _, new in
            keepsAspect = new == .resize
            reset()
        }
    }

    private func sizeField(_ label: String, value: Binding<Int>, changed: @escaping (Int) -> Void) -> some View {
        TextField(label, value: Binding(get: { value.wrappedValue }, set: { new in
            let clamped = min(max(new, 1), 32_000)
            value.wrappedValue = clamped
            changed(clamped)
        }), format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.center)
        .monospacedDigit()
        .frame(width: 76)
        .help("\(label) (px)")
    }

    private func reset() {
        width = Int(original.width)
        height = Int(original.height)
        anchor = .center
    }

    private func applyPercent(_ percent: Int) {
        width = max(Int((original.width * CGFloat(percent) / 100).rounded()), 1)
        height = max(Int((original.height * CGFloat(percent) / 100).rounded()), 1)
    }

    private func apply() {
        let size = CGSize(width: width, height: height)
        switch mode {
        case .resize: model.resizeImage(toDisplayed: size)
        case .canvas: model.resizeCanvas(toDisplayed: size, anchor: anchor)
        }
        model.showsSizePopover = false
    }
}
