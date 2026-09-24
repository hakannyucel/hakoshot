import AppKit
import SwiftUI

/// One Quick Access card (report §7, plan §4.12): rounded thumbnail with the floating
/// card shadow; on hover the shared `HoverControlsOverlay` (Close / Pin / Edit /
/// Show in Finder corners, Copy / Save pills). Right-click opens the same actions.
/// Hover state comes from the panel's tracking area (works while the app is inactive).
struct QuickAccessCardView: View {
    let card: QuickAccessCard
    let onAction: (QuickAccessAction) -> Void
    /// Called once when a drag gesture starts on the card; the controller starts an
    /// AppKit dragging session (`DragSource`) from the current mouse event.
    let onDragStart: () -> Void

    private let cornerRadius = Tokens.Radius.quickAccessCard

    var body: some View {
        ZStack {
            Image(nsImage: card.thumbnail)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: card.size.width, height: card.size.height, alignment: .top)
                .clipped()

            HoverControlsOverlay(
                isVisible: card.isHovered && !card.isDragging,
                topLeading: HoverCornerControl(systemImage: "xmark", label: "Close") { onAction(.close) },
                topTrailing: HoverCornerControl(systemImage: "pin.fill", label: "Pin") { onAction(.pin) },
                bottomLeading: HoverCornerControl(systemImage: "pencil", label: "Edit") { onAction(.edit) },
                bottomTrailing: HoverCornerControl(systemImage: "folder", label: "Show in Finder") { onAction(.showInFinder) },
                centerPills: [
                    HoverPillControl(title: "Copy") {
                        onAction(.copy(keepOpen: NSEvent.modifierFlags.contains(.option)))
                    },
                    HoverPillControl(title: "Save") { onAction(.save) },
                ],
                cornerRadius: cornerRadius
            )
        }
        .frame(width: card.size.width, height: card.size.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .copyFlash(trigger: card.copyFlashCount, cornerRadius: cornerRadius)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: Tokens.Palette.hudBorder), lineWidth: Tokens.Stroke.hairline)
                .allowsHitTesting(false)
        }
        .dsShadow(.floatingCard)
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    if !card.isDragging { onDragStart() }
                }
        )
        .contextMenu { contextMenu }
        .padding(QuickAccessLayout.shadowMargin)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshot preview")
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy") { onAction(.copy(keepOpen: false)) }
        Button("Save") { onAction(.save) }
        Button("Save As…") { onAction(.saveAs) }
        Divider()
        Button("Open in Editor") { onAction(.edit) }
        Button("Pin to Screen") { onAction(.pin) }
        if card.savedURL != nil {
            Button("Show in Finder") { onAction(.showInFinder) }
        }
        Divider()
        Button("Close") { onAction(.close) }
        Button("Close All") { onAction(.closeAll) }
    }
}
