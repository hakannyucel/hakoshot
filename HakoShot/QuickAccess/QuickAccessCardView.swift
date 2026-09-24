import AppKit
import SwiftUI

/// One Quick Access card (report §7, plan §4.12; video cards kayit-teknik-plan §4.15):
/// rounded thumbnail with the floating card shadow; on hover the shared
/// `HoverControlsOverlay`. Right-click opens the same actions. Hover state comes from
/// the panel's tracking area (works while the app is inactive).
///
/// Image cards: Close / Pin / Edit / Show in Finder corners, Copy / Save pills.
/// Video cards: Close / Convert to GIF / Edit (video editor) / Show in Finder corners,
/// Copy / Save pills, and a duration badge (+ GIF progress while converting); no Pin or Annotate.
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

            if card.controls.durationBadge, let duration = card.durationText {
                QuickAccessDurationBadge(
                    duration: duration,
                    isGIF: card.recording?.format == .gif
                )
                .padding(Tokens.Recording.durationBadgeInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                // The Edit corner control takes the same spot while hovered.
                .opacity(card.isHovered && card.controls.editVideo ? 0 : 1)
                .allowsHitTesting(false)
            }

            if let progress = card.conversionProgress {
                QuickAccessConversionBadge(progress: progress)
                    .padding(Tokens.Recording.durationBadgeInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }

            HoverControlsOverlay(
                isVisible: card.isHovered && !card.isDragging,
                topLeading: HoverCornerControl(systemImage: "xmark", label: "Close") { onAction(.close) },
                topTrailing: topTrailingControl,
                bottomLeading: bottomLeadingControl,
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
        .accessibilityLabel(card.item.isVideo ? "Recording preview" : "Screenshot preview")
    }

    /// Image: Pin. Video: Convert to GIF once R3 provides it (hidden until then).
    private var topTrailingControl: HoverCornerControl? {
        if card.controls.pin {
            return HoverCornerControl(systemImage: "pin.fill", label: "Pin") { onAction(.pin) }
        }
        if card.controls.convertToGIF {
            return HoverCornerControl(systemImage: "photo.stack", label: "Convert to GIF") { onAction(.convertToGIF) }
        }
        return nil
    }

    /// Image: Annotate. Video: video editor once R3 provides it (hidden until then).
    private var bottomLeadingControl: HoverCornerControl? {
        if card.controls.annotate {
            return HoverCornerControl(systemImage: "pencil", label: "Edit") { onAction(.edit) }
        }
        if card.controls.editVideo {
            return HoverCornerControl(systemImage: "scissors", label: "Edit Video") { onAction(.edit) }
        }
        return nil
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Copy") { onAction(.copy(keepOpen: false)) }
        Button("Save") { onAction(.save) }
        Button("Save As…") { onAction(.saveAs) }
        if card.item.isVideo {
            if card.controls.editVideo || card.controls.openInStudio || card.controls.convertToGIF {
                Divider()
            }
            if card.controls.editVideo {
                Button("Open in Video Editor") { onAction(.edit) }
            }
            if card.controls.openInStudio {
                Button("Open in Studio") { onAction(.openInStudio) }
            }
            if card.controls.convertToGIF {
                Button("Convert to GIF") { onAction(.convertToGIF) }
            }
            Divider()
            Button("Show in Finder") { onAction(.showInFinder) }
        } else {
            Divider()
            Button("Open in Editor") { onAction(.edit) }
            Button("Pin to Screen") { onAction(.pin) }
            if card.savedURL != nil {
                Button("Show in Finder") { onAction(.showInFinder) }
            }
        }
        Divider()
        Button("Close") { onAction(.close) }
        Button("Close All") { onAction(.closeAll) }
    }
}

/// Top-center pill while Convert to GIF runs: "GIF" + a small bar + percent.
struct QuickAccessConversionBadge: View {
    let progress: Double

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text("GIF")
            ProgressView(value: progress)
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .frame(width: Tokens.Recording.durationBadgeHeight * 3)
            Text(progress, format: .percent.precision(.fractionLength(0)))
                .monospacedDigit()
        }
        .font(Tokens.Recording.durationBadgeFont)
        .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(height: Tokens.Recording.durationBadgeHeight)
        .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.hudControlFill)))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Converting to GIF")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
    }
}

/// Bottom-left badge on video cards: "▶︎ 0:42" (mp4) or "GIF 0:04".
struct QuickAccessDurationBadge: View {
    let duration: String
    let isGIF: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if isGIF {
                Text("GIF")
            } else {
                Image(systemName: "play.fill")
                    .imageScale(.small)
            }
            Text(duration)
        }
        .font(Tokens.Recording.durationBadgeFont)
        .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextPrimary))
        .padding(.horizontal, Tokens.Spacing.s)
        .frame(height: Tokens.Recording.durationBadgeHeight)
        .background(Capsule(style: .continuous).fill(Color(nsColor: Tokens.Palette.hudControlFill)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isGIF ? "GIF, \(duration)" : "Video, \(duration)")
    }
}
