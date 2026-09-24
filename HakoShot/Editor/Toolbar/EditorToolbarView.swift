import AppKit
import HakoKit
import SwiftUI

/// Top bar (plan §4.11, report §9.1): traffic lights (AppKit) → [Crop | Add image | Background]
/// capsule → divider → drawing tools → option bar for the current tool /
/// selection → "Save as…" + "Done" on the right. In crop mode the whole bar is
/// the crop bar (report §9.4) after the capsule.
struct EditorToolbarView: View {
    let model: EditorViewModel
    let onSaveAs: () -> Void
    let onDone: () -> Void

    var body: some View {
        HStack(spacing: EditorMetrics.toolbarGroupSpacing) {
            canvasToolGroup
            ToolbarDivider()
            if let session = model.cropSession {
                CropBar(model: model, session: session)
            } else {
                annotationControls
            }
        }
        .padding(.leading, EditorMetrics.toolbarLeadingInset)
        .padding(.trailing, EditorMetrics.toolbarTrailingInset)
        .frame(maxWidth: .infinity, minHeight: EditorMetrics.toolbarHeight, maxHeight: EditorMetrics.toolbarHeight)
        .background {
            // Empty toolbar areas drag the window (our content covers the titlebar);
            // double-click zooms like a real titlebar.
            Color.clear
                .contentShape(Rectangle())
                .gesture(WindowDragGesture())
                .onTapGesture(count: 2) { NSApp.keyWindow?.performZoom(nil) }
        }
        .allowsWindowActivationEvents(true)
        // The bar lives under the (transparent) titlebar; don't inset for it.
        .ignoresSafeArea()
        .animation(DSAnimation.hoverControls, value: model.options?.tool)
    }

    @ViewBuilder
    private var annotationControls: some View {
        HStack(spacing: EditorMetrics.toolbarItemSpacing) {
            ForEach(EditorToolDescriptor.drawingTools) { descriptor in
                EditorToolButton(
                    symbol: descriptor.symbol,
                    help: descriptor.help,
                    isActive: model.tool == descriptor.tool
                ) {
                    model.selectTool(descriptor.tool)
                }
            }
        }
        .fixedSize()
        .layoutPriority(2)
        if let options = model.options {
            ToolbarDivider()
            ViewThatFits(in: .horizontal) {
                ToolOptionsBar(model: model, options: options)
                ToolOptionsBar(model: model, options: options, compact: true)
            }
            .transition(.opacity)
        }
        Spacer(minLength: 0)
        HStack(spacing: Tokens.Spacing.s) {
            PillButton("Save as…", style: .neutral, action: onSaveAs)
                .help("Save As… (⇧⌘S)")
            PillButton("Done", style: .primary, action: onDone)
                .help("Save and close")
        }
        .fixedSize()
        .layoutPriority(2)
    }

    private var canvasToolGroup: some View {
        HStack(spacing: 0) {
            canvasToolButton(.crop)
            // Report §9.1: [Crop | Add image | Background].
            EditorToolButton(symbol: "photo.badge.plus", help: "Add Image (⌘I, ⇧⌘I new screenshot)") {
                model.chooseImagesToCombine(from: model.hostWindow)
            }
            canvasToolButton(.background)
        }
        .padding(.horizontal, Tokens.Spacing.xxs)
        .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.neutralPillFill)))
        .fixedSize()
        .layoutPriority(2)
    }
}

extension EditorToolbarView {
    private func canvasToolButton(_ tool: AnnotationTool) -> some View {
        let descriptor = EditorToolDescriptor.descriptor(for: tool)
        return EditorToolButton(
            symbol: descriptor.symbol,
            help: descriptor.help,
            isActive: tool == .crop ? model.isCropping : model.showsBackgroundPanel
        ) {
            model.selectTool(tool)
        }
    }
}

struct ToolbarDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Tokens.Palette.divider))
            .frame(width: Tokens.Stroke.hairline, height: 22)
    }
}

/// Square tool button; active = accent fill with white glyph (report §9.1).
struct EditorToolButton: View {
    let symbol: String
    let help: String
    var isActive = false
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: EditorMetrics.toolIconSize, weight: .medium))
                .frame(width: EditorMetrics.toolButtonSize, height: EditorMetrics.toolButtonSize)
                .foregroundStyle(isActive ? Color.white : Color(nsColor: Tokens.Palette.textPrimary))
                .background(
                    RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight, style: .continuous)
                        .fill(background)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .help(help)
        .accessibilityLabel(help)
        .onHover { hovering = $0 }
        .animation(DSAnimation.hoverControls, value: hovering)
    }

    private var background: Color {
        if isActive { return .accentColor }
        return hovering && isEnabled ? Color(nsColor: Tokens.Palette.selectionFill) : .clear
    }
}
