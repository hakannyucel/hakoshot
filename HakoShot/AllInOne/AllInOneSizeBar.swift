import AppKit
import SwiftUI

// The size bar pieces shared by the All-In-One bar (WP3.4) and the
// pre-record HUD (kayit-teknik-plan §4.2, R1.1): the `W × H` fields, the
// aspect-ratio button and the ratio menu. Moved out of `AllInOneBarView`
// unchanged; the owner's model conforms to `SizeBarModel` and the owner
// passes its actions as closures (capture the owner weakly).

/// State the size bar reads and edits (`AllInOneModel`, `RecordingHUDModel`).
protocol SizeBarModel: AnyObject, Observable {
    var widthText: String { get set }
    var heightText: String { get set }
    /// A size field has focus: don't overwrite what the user is typing.
    var isEditingSize: Bool { get set }
    /// Selection size in points; `nil` without a selection.
    var selectionSize: CGSize? { get }
    var isWindowMode: Bool { get }
    var ratio: AspectRatioPreset { get }
    var showsRatioMenu: Bool { get }
    /// Rewrites the texts from `selectionSize` (unless editing).
    func updateSizeTexts()
}

// MARK: - Size fields

/// `W × H` point fields. `onSubmit(editedWidth)` runs after Return in a field.
struct SizeBarFields<Model: SizeBarModel>: View {
    @Bindable var model: Model
    let onSubmit: (_ editedWidth: Bool) -> Void
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
                onSubmit(field == .width)
            }
            .help(field == .width ? "Width in points" : "Height in points")
    }
}

// MARK: - Divider

/// Vertical hairline between size bar groups.
struct SizeBarDivider: View {
    var height: CGFloat = 28

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Tokens.Palette.hudBorder))
            .frame(width: Tokens.Stroke.hairline, height: height)
            .padding(.horizontal, Tokens.Spacing.xxs)
    }
}

// MARK: - Aspect ratio

/// Lock / ratio title / chevron; toggles the ratio menu.
struct SizeBarRatioButton<Model: SizeBarModel>: View {
    let model: Model
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

/// `presets` + a separator + "Custom (current)". `onSelect` gets `.custom(0)`
/// for the custom row; the owner resolves it from the current selection.
struct SizeBarRatioMenu<Model: SizeBarModel>: View {
    let model: Model
    var presets: [AspectRatioPreset] = AspectRatioPreset.menu
    let onSelect: (AspectRatioPreset) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(presets, id: \.self) { preset in
                row(preset, checked: model.ratio == preset)
            }
            HUDMenuSeparator()
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
        HUDMenuRow(title: title ?? preset.title, checked: checked) {
            onSelect(preset)
        }
    }
}

// MARK: - Menu rows

/// Hairline between HUD menu sections.
struct HUDMenuSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: Tokens.Palette.hudBorder))
            .frame(height: Tokens.Stroke.hairline)
            .padding(.vertical, Tokens.Spacing.xs)
    }
}

/// One row of a HUD menu: check column, optional icon, title, optional
/// trailing text (shortcut). Without `icon` / `trailing` it is the
/// All-In-One ratio menu row.
struct HUDMenuRow<Icon: View>: View {
    let title: String
    var checked = false
    /// `false` hides the check column (action menus like Record Video / GIF).
    var showsCheckColumn = true
    var trailing: String?
    var isEnabled = true
    let icon: Icon
    let action: () -> Void
    @State private var hovering = false

    init(
        title: String, checked: Bool = false, showsCheckColumn: Bool = true, trailing: String? = nil,
        isEnabled: Bool = true, @ViewBuilder icon: () -> Icon, action: @escaping () -> Void
    ) {
        self.title = title
        self.checked = checked
        self.showsCheckColumn = showsCheckColumn
        self.trailing = trailing
        self.isEnabled = isEnabled
        self.icon = icon()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Tokens.Spacing.s) {
                if showsCheckColumn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .opacity(checked ? 1 : 0)
                }
                icon
                Text(title)
                    .font(Tokens.Typography.rowLabel)
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(Tokens.Typography.rowLabel)
                        .foregroundStyle(Color(nsColor: hovering ? Tokens.Palette.hudTextPrimary : Tokens.Palette.hudTextSecondary))
                }
            }
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
            .padding(.horizontal, Tokens.Spacing.s)
            .frame(height: Tokens.AllInOne.menuRowHeight)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering && isEnabled ? Color.accentColor.opacity(0.85) : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
    }
}

extension HUDMenuRow where Icon == EmptyView {
    init(title: String, checked: Bool, action: @escaping () -> Void) {
        self.init(title: title, checked: checked, icon: { EmptyView() }, action: action)
    }
}

// MARK: - Math

/// Pure size-bar arithmetic (tested; the HUD uses it, the All-In-One bar has
/// the same rules inline in `AllInOneBar.submitSize`).
nonisolated enum SizeBarMath {
    /// The size to apply after a field was submitted: parses both texts,
    /// under a locked ratio the edited side decides the other, rounds to
    /// whole points. `nil` = invalid (keep the selection, reset the texts).
    static func submittedSize(
        widthText: String, heightText: String, current: CGSize?, ratio: CGFloat?, editedWidth: Bool
    ) -> CGSize? {
        let width = Double(widthText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let height = Double(heightText.trimmingCharacters(in: .whitespaces)).map { CGFloat($0) }
        let current = current ?? CGSize(width: width ?? height ?? 0, height: height ?? width ?? 0)
        var size = ratio == nil
            ? CGSize(width: width ?? current.width, height: height ?? current.height)
            : AspectRatioPreset.size(
                width: editedWidth ? width : nil, height: editedWidth ? nil : height, current: current, ratio: ratio
            )
        size.width = size.width.rounded()
        size.height = size.height.rounded()
        guard size.width >= 1, size.height >= 1 else { return nil }
        return size
    }

    /// A selection re-fitted to a newly chosen ratio, like
    /// `OverlayAccessoryHost.aspectRatio`'s setter: keeps the width; when the
    /// height doesn't fit `maxHeight` (room left on the display), keeps the
    /// ratio at that height instead. Freeform leaves it as is.
    static func fitted(_ size: CGSize, to ratio: CGFloat?, maxHeight: CGFloat = .infinity) -> CGSize {
        guard let ratio, ratio > 0, ratio.isFinite else { return size }
        let height = (size.width / ratio).rounded()
        guard height > maxHeight else { return CGSize(width: size.width, height: height) }
        return CGSize(width: (maxHeight * ratio).rounded(), height: maxHeight)
    }
}
