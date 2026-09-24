import AppKit
import SwiftUI

struct AllInOneBarView: View {
    let model: AllInOneModel
    let actions: AllInOneBarActions

    private var barHeight: CGFloat { Tokens.AllInOne.itemHeight + Tokens.AllInOne.barPaddingV * 2 }

    var body: some View {
        VStack(alignment: .trailing, spacing: Tokens.Spacing.s) {
            if model.showsRatioMenu {
                RatioMenu(model: model, actions: actions)
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
            SizeFields(model: model, actions: actions)
            Rectangle()
                .fill(Color(nsColor: Tokens.Palette.hudBorder))
                .frame(width: Tokens.Stroke.hairline, height: 28)
                .padding(.horizontal, Tokens.Spacing.xxs)
            RatioButton(model: model) { actions.bar?.toggleRatioMenu() }
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

// MARK: - Size fields

private struct SizeFields: View {
    @Bindable var model: AllInOneModel
    let actions: AllInOneBarActions
    @FocusState private var focus: Field?

    private enum Field { case width, height }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            field("W", text: $model.widthText, field: .width)
            Image(systemName: "multiply")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
            field("H", text: $model.heightText, field: .height)
        }
        .onChange(of: focus) { _, newValue in
            model.isEditingSize = newValue != nil
            if newValue == nil { model.updateSizeTexts() }
        }
        .disabled(model.isWindowMode)
        .opacity(model.isWindowMode ? 0.45 : 1)
    }

    private func field(_ placeholder: String, text: Binding<String>, field: Field) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Tokens.Typography.pillLabel.monospacedDigit())
            .multilineTextAlignment(.center)
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            .focused($focus, equals: field)
            .frame(width: Tokens.AllInOne.sizeFieldWidth, height: Tokens.AllInOne.sizeFieldHeight)
            .background {
                RoundedRectangle(cornerRadius: Tokens.AllInOne.sizeFieldRadius, style: .continuous)
                    .fill(Tokens.AllInOne.fieldFill)
            }
            .overlay {
                if focus == field {
                    RoundedRectangle(cornerRadius: Tokens.AllInOne.sizeFieldRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: Tokens.Stroke.hairline)
                }
            }
            .onSubmit {
                focus = nil
                model.isEditingSize = false
                actions.bar?.submitSize(editedWidth: field == .width)
            }
            .help(field == .width ? "Width in points" : "Height in points")
    }
}

// MARK: - Aspect ratio

private struct RatioButton: View {
    let model: AllInOneModel
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: model.ratio.isLocked ? "lock.fill" : "aspectratio")
                    .font(.system(size: 13, weight: .medium))
                Text(model.ratio.title)
                    .font(Tokens.Typography.pillLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(model.showsRatioMenu ? 180 : 0))
            }
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(height: Tokens.AllInOne.sizeFieldHeight + 4)
            .background {
                RoundedRectangle(cornerRadius: Tokens.AllInOne.sizeFieldRadius, style: .continuous)
                    .fill(hovering || model.showsRatioMenu ? Tokens.AllInOne.fieldFill : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Aspect ratio")
    }
}

private struct RatioMenu: View {
    let model: AllInOneModel
    let actions: AllInOneBarActions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(AspectRatioPreset.menu, id: \.self) { preset in
                row(preset, checked: model.ratio == preset)
            }
            Rectangle()
                .fill(Color(nsColor: Tokens.Palette.hudBorder))
                .frame(height: Tokens.Stroke.hairline)
                .padding(.vertical, Tokens.Spacing.xs)
            row(.custom(0), title: "Custom (current)", checked: isCustom)
        }
        .padding(Tokens.Spacing.xs + 2)
        .frame(width: Tokens.AllInOne.menuWidth)
        .hudPanel(cornerRadius: Tokens.AllInOne.menuRadius, shadow: .toast)
    }

    private var isCustom: Bool {
        if case .custom = model.ratio { return true }
        return false
    }

    private func row(_ preset: AspectRatioPreset, title: String? = nil, checked: Bool) -> some View {
        MenuRow(title: title ?? preset.title, checked: checked) {
            actions.bar?.selectRatio(preset)
        }
    }
}

private struct MenuRow: View {
    let title: String
    let checked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(checked ? 1 : 0)
                Text(title)
                    .font(Tokens.Typography.rowLabel)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(height: Tokens.AllInOne.menuRowHeight)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color.accentColor.opacity(0.85) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
