import AppKit
import SwiftUI

struct AllInOneBarView: View {
    let model: AllInOneModel
    let actions: AllInOneBarActions

    private var barHeight: CGFloat { Tokens.AllInOne.itemHeight + Tokens.AllInOne.barPaddingV * 2 }

    var body: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.s) {
            if model.showsRatioMenu {
                SizeBarRatioMenu(model: model) { actions.bar?.selectRatio($0) }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            HStack(spacing: Tokens.AllInOne.barGap) {
                modeBar
                sizeBar
            }
        }
        .padding(Tokens.Spacing.l) // room for the HUD shadow
        .animation(DSAnimation.popoverIn, value: model.showsRatioMenu)
        .fixedSize()
    }

    // MARK: Mode bar

    private var modeBar: some View {
        HStack(spacing: Tokens.AllInOne.itemGap) {
            ForEach(AllInOneMode.allCases, id: \.self) { mode in
                ModeButton(mode: mode, isActive: model.activeMode == mode) {
                    actions.bar?.tap(mode)
                }
            }
        }
        .padding(.horizontal, Tokens.AllInOne.barPaddingH)
        .padding(.vertical, Tokens.AllInOne.barPaddingV)
        .frame(height: barHeight)
        .hudPanel(cornerRadius: Tokens.Radius.hudBar)
    }

    // MARK: Size bar

    private var sizeBar: some View {
        HStack(spacing: Tokens.Spacing.s) {
            SizeBarFields(model: model) { actions.bar?.submitSize(editedWidth: $0) }
            SizeBarDivider()
            SizeBarRatioButton(model: model) { actions.bar?.toggleRatioMenu() }
            Button {
                actions.bar?.captureTapped()
            } label: {
                Label("Capture", systemImage: "camera.fill").labelStyle(.titleOnly)
            }
            .buttonStyle(PillButtonStyle(style: .hudLight))
            .disabled(model.selectionSize == nil || model.isWindowMode)
            .help("Capture the selection (Return)")
        }
        .padding(.leading, Tokens.Spacing.l)
        .padding(.trailing, Tokens.Spacing.m)
        .frame(height: barHeight)
        .hudPanel(cornerRadius: Tokens.Radius.hudBar)
    }
}

// MARK: - Mode button

private struct ModeButton: View {
    let mode: AllInOneMode
    let isActive: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: Tokens.AllInOne.iconLabelGap) {
                Image(systemName: mode.symbol)
                    .font(.system(size: Tokens.AllInOne.iconSize, weight: .regular))
                    .frame(height: Tokens.Size.hudIcon)
                Text(mode.title)
                    .font(Tokens.Typography.hudLabel)
                    .lineLimit(1)
            }
            .foregroundStyle(Color(nsColor: isActive ? Tokens.Palette.hudTextPrimary : Tokens.Palette.hudTextSecondary))
            .frame(width: Tokens.AllInOne.itemWidth, height: Tokens.AllInOne.itemHeight)
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.hudItemHighlight, style: .continuous)
                    .fill(highlight)
            }
            .contentShape(RoundedRectangle(cornerRadius: Tokens.Radius.hudItemHighlight, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!mode.isAvailable)
        .opacity(mode.isAvailable ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(DSAnimation.hoverControls, value: hovering)
        .help(mode.isAvailable ? mode.title : "\(mode.title) is not available")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private var highlight: Color {
        if isActive { return Color(nsColor: Tokens.Palette.hudItemHighlight) }
        return hovering && mode.isAvailable ? Tokens.AllInOne.hoverFill : .clear
    }
}

extension AllInOneModel: SizeBarModel {}
