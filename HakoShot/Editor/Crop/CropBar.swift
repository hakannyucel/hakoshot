import AppKit
import HakoKit
import SwiftUI

/// Crop mode's own top bar (report §9.4): ratio menu, W × H fields,
/// rotate / flip, "Image size", then Revert to Original / Cancel / Crop.
struct CropBar: View {
    let model: EditorViewModel
    let session: CropSession

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            Menu {
                ForEach(CropAspect.menu, id: \.self) { aspect in
                    Button {
                        model.updateCrop { $0.setAspect(aspect) }
                    } label: {
                        if aspect == session.aspect { Label(aspect.label, systemImage: "checkmark") } else { Text(aspect.label) }
                    }
                    if aspect == .original { Divider() }
                }
            } label: {
                Text(session.aspect.label)
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Aspect ratio")

            HStack(spacing: Tokens.Spacing.xs) {
                CropSizeField(value: Int(session.rect.width), help: "Width (px)") { width in
                    model.updateCrop { s in
                        let height = s.ratio.map { CropMath.linked(width: CGFloat(width), ratio: $0) } ?? s.rect.height
                        s.setSize(width: CGFloat(width), height: height)
                    }
                }
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                CropSizeField(value: Int(session.rect.height), help: "Height (px)") { height in
                    model.updateCrop { s in
                        let width = s.ratio.map { CropMath.linked(height: CGFloat(height), ratio: $0) } ?? s.rect.width
                        s.setSize(width: width, height: CGFloat(height))
                    }
                }
            }

            ToolbarDivider()
            HStack(spacing: Tokens.Spacing.xxs) {
                EditorToolButton(symbol: "rotate.left", help: "Rotate Left") { model.rotate(clockwise: false) }
                EditorToolButton(symbol: "rotate.right", help: "Rotate Right") { model.rotate(clockwise: true) }
                EditorToolButton(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right", help: "Flip Horizontal") {
                    model.flip(horizontal: true)
                }
                EditorToolButton(symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down", help: "Flip Vertical") {
                    model.flip(horizontal: false)
                }
            }
            .fixedSize()

            Text(verbatim: "Image size: \(Int(session.bounds.width)) × \(Int(session.bounds.height)) px")
                .font(.system(size: 12))
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                .lineLimit(1)
                .layoutPriority(-1)

            Spacer(minLength: 0)
            HStack(spacing: Tokens.Spacing.s) {
                PillButton("Revert to Original", style: .neutral) { model.updateCrop { $0.revert() } }
                    .disabled(session.isFullImage && session.aspect == .freeform)
                    .help("Show the whole image")
                PillButton("Cancel", style: .neutral) { model.cancelCrop() }
                    .help("Cancel (Esc)")
                PillButton("Crop", style: .primary) { model.applyCrop() }
                    .help("Crop (Return)")
            }
            .fixedSize()
        }
    }
}

/// Integer pixel field; commits on Return / focus loss.
private struct CropSizeField: View {
    let value: Int
    let help: String
    let commit: (Int) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .monospacedDigit()
            .font(.system(size: 12))
            .frame(width: EditorMetrics.cropSizeFieldWidth)
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
