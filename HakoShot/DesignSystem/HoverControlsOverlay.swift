import SwiftUI

/// One round corner control of the hover layer.
struct HoverCornerControl {
    let systemImage: String
    let label: String
    let action: () -> Void
}

/// One centered pill of the hover layer ("Copy", "Save").
struct HoverPillControl {
    let title: String
    var systemImage: String?
    let action: () -> Void
}

/// Shared hover control layer of Quick Access cards and Pin windows (report §7, §8, §13):
/// a dark scrim, round buttons in the four corners and vertically stacked light pills
/// in the center. Fades in/out with `DSAnimation.hoverControls`.
///
/// Quick Access (plan §4.12): top-leading Close, top-trailing Pin, bottom-leading Edit,
/// bottom-trailing Show in Finder, center Copy / Save.
struct HoverControlsOverlay: View {
    var isVisible: Bool
    var topLeading: HoverCornerControl?
    var topTrailing: HoverCornerControl?
    var bottomLeading: HoverCornerControl?
    var bottomTrailing: HoverCornerControl?
    var centerPills: [HoverPillControl] = []
    var cornerRadius: CGFloat = Tokens.Radius.quickAccessCard

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(nsColor: Tokens.Palette.hudScrim))

            VStack(spacing: Tokens.Spacing.hoverPillGap) {
                ForEach(centerPills.indices, id: \.self) { index in
                    let pill = centerPills[index]
                    PillButton(pill.title, systemImage: pill.systemImage, style: .hudLight, fillsWidth: true, action: pill.action)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            corner(topLeading, alignment: .topLeading)
            corner(topTrailing, alignment: .topTrailing)
            corner(bottomLeading, alignment: .bottomLeading)
            corner(bottomTrailing, alignment: .bottomTrailing)
        }
        .environment(\.colorScheme, .dark)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .animation(DSAnimation.hoverControls, value: isVisible)
    }

    @ViewBuilder
    private func corner(_ control: HoverCornerControl?, alignment: Alignment) -> some View {
        if let control {
            CircleIconButton(systemImage: control.systemImage, accessibilityLabel: control.label, action: control.action)
                .padding(Tokens.Spacing.hoverControlInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        }
    }
}

extension View {
    /// Overlays `HoverControlsOverlay` and shows it while the pointer is inside the view.
    func hoverControls(
        topLeading: HoverCornerControl? = nil,
        topTrailing: HoverCornerControl? = nil,
        bottomLeading: HoverCornerControl? = nil,
        bottomTrailing: HoverCornerControl? = nil,
        centerPills: [HoverPillControl] = [],
        cornerRadius: CGFloat = Tokens.Radius.quickAccessCard,
        forceVisible: Bool = false
    ) -> some View {
        modifier(HoverControlsModifier(
            topLeading: topLeading,
            topTrailing: topTrailing,
            bottomLeading: bottomLeading,
            bottomTrailing: bottomTrailing,
            centerPills: centerPills,
            cornerRadius: cornerRadius,
            forceVisible: forceVisible
        ))
    }
}

private struct HoverControlsModifier: ViewModifier {
    let topLeading: HoverCornerControl?
    let topTrailing: HoverCornerControl?
    let bottomLeading: HoverCornerControl?
    let bottomTrailing: HoverCornerControl?
    let centerPills: [HoverPillControl]
    let cornerRadius: CGFloat
    let forceVisible: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                HoverControlsOverlay(
                    isVisible: hovering || forceVisible,
                    topLeading: topLeading,
                    topTrailing: topTrailing,
                    bottomLeading: bottomLeading,
                    bottomTrailing: bottomTrailing,
                    centerPills: centerPills,
                    cornerRadius: cornerRadius
                )
            }
            .onHover { hovering = $0 }
    }
}
