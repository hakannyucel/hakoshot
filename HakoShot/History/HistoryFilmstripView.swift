import AppKit
import HakoKit
import Observation
import SwiftUI

/// State shown by `HistoryFilmstripView`; owned by `HistoryOverlayController`.
@Observable
final class HistoryOverlayModel {
    var filter: HistoryFilter = .all
    var items: [HistoryItem] = []
    var selectedID: UUID?
    var thumbnails: [UUID: NSImage] = [:]
    var previews: [UUID: NSImage] = [:]
    /// Short feedback ("Copied") shown under the Restore pill.
    var toast: String?

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return items.firstIndex { $0.id == selectedID }
    }

    var selectedItem: HistoryItem? {
        selectedIndex.map { items[$0] }
    }

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), items.count - 1)
        selectedID = items[next].id
    }

    /// Replaces the list, keeping the selection (or its neighbour) when possible.
    func setItems(_ newItems: [HistoryItem]) {
        let previousIndex = selectedIndex ?? 0
        items = newItems
        if let selectedID, newItems.contains(where: { $0.id == selectedID }) { return }
        selectedID = newItems.isEmpty ? nil : newItems[min(previousIndex, newItems.count - 1)].id
    }
}

/// Actions the view forwards to the controller.
struct HistoryFilmstripActions {
    var selectFilter: (HistoryFilter) -> Void
    var restore: () -> Void
    var close: () -> Void
}

/// Full-screen dark HUD with filter pills, a horizontal filmstrip of recent
/// captures (selected card enlarged, accent ring) and a "Restore" pill
/// (report §10, plan §4.12).
struct HistoryFilmstripView: View {
    @Bindable var model: HistoryOverlayModel
    let actions: HistoryFilmstripActions

    var body: some View {
        GeometryReader { geo in
            let selectedHeight = min(geo.size.height * Tokens.History.selectedCardHeightFraction, Tokens.History.selectedCardMaxHeight)
            ZStack {
                HUDMaterial(cornerRadius: 0)
                Color.black.opacity(Tokens.History.backdropTint)
                    .contentShape(Rectangle())
                    .onTapGesture { actions.close() }

                VStack(spacing: 0) {
                    filterBar
                        .padding(.top, Tokens.History.topInset)
                    Spacer(minLength: Tokens.Spacing.xl)
                    if model.items.isEmpty {
                        emptyState
                    } else {
                        filmstrip(width: geo.size.width, selectedHeight: selectedHeight)
                        restoreBar
                            .padding(.top, Tokens.Spacing.xl)
                    }
                    Spacer(minLength: Tokens.Spacing.xl)
                    hints
                        .padding(.bottom, Tokens.History.bottomInset)
                }
            }
        }
        .environment(\.colorScheme, .dark)
        .ignoresSafeArea()
    }

    // MARK: Parts

    private var filterBar: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ForEach(HistoryFilter.allCases, id: \.self) { filter in
                PillButton(filter.title, style: filter == model.filter ? .primary : .hudDark) {
                    actions.selectFilter(filter)
                }
            }
        }
    }

    /// Carousel: the row is offset so the selected card's center sits on
    /// the screen's center (deterministic, unlike a `ScrollView` + `scrollTo`,
    /// which left the first card off-center on first show).
    private func filmstrip(width: CGFloat, selectedHeight: CGFloat) -> some View {
        let sideHeight = selectedHeight * Tokens.History.sideCardScale
        let widths = model.items.map { item in
            (item.id == model.selectedID ? selectedHeight : sideHeight) * HistoryCard.aspect(of: item)
        }
        let index = model.selectedIndex ?? 0
        let before = widths.prefix(index).reduce(0) { $0 + $1 + Tokens.History.cardGap }
        let selectedCenter = before + (widths.indices.contains(index) ? widths[index] / 2 : 0)
        return HStack(alignment: .center, spacing: Tokens.History.cardGap) {
            ForEach(model.items) { item in
                HistoryCard(
                    item: item,
                    image: image(for: item),
                    isSelected: item.id == model.selectedID,
                    height: item.id == model.selectedID ? selectedHeight : sideHeight
                )
                .onTapGesture(count: 2) {
                    model.selectedID = item.id
                    actions.restore()
                }
                .onTapGesture { model.selectedID = item.id }
            }
        }
        .fixedSize()
        .offset(x: width / 2 - selectedCenter)
        .frame(width: width, height: selectedHeight + Tokens.Stroke.selectionRing * 4, alignment: .leading)
        .clipped()
        .animation(DSAnimation.respectingReduceMotion(DSAnimation.quickAccessSlideIn), value: model.selectedID)
    }

    private var restoreBar: some View {
        VStack(spacing: Tokens.Spacing.s) {
            PillButton("Restore", systemImage: "return", style: .primary) { actions.restore() }
            Text(model.toast ?? subtitle)
                .font(Tokens.Typography.hudLabel)
                .foregroundStyle(Color(nsColor: model.toast == nil ? Tokens.Palette.hudTextSecondary : Tokens.Palette.hudTextPrimary))
                .monospacedDigit()
        }
    }

    private var emptyState: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40, weight: .light))
            Text(model.filter == .all ? "No captures yet" : "No \(model.filter.title.lowercased()) captures")
                .font(Tokens.Typography.pillLabel)
        }
        .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
    }

    private var hints: some View {
        Text("←  →  Browse     ↩  Restore     ⌘C  Copy     ⌘E  Edit     ⌘P  Pin     ⌫  Delete     esc  Close")
            .font(Tokens.Typography.hudLabel)
            .foregroundStyle(Color(nsColor: Tokens.Palette.hudTextSecondary))
    }

    private var subtitle: String {
        guard let item = model.selectedItem, let index = model.selectedIndex else { return " " }
        let date = item.date.formatted(.relative(presentation: .named))
        let size = "\(Int(item.pointWidth.rounded())) × \(Int(item.pointHeight.rounded()))"
        return "\(date)  ·  \(size)  ·  \(index + 1) of \(model.items.count)"
    }

    private func image(for item: HistoryItem) -> NSImage? {
        if item.id == model.selectedID, let preview = model.previews[item.id] { return preview }
        return model.thumbnails[item.id]
    }
}

/// One rounded capture card; enlarged with an accent ring when selected.
private struct HistoryCard: View {
    let item: HistoryItem
    let image: NSImage?
    let isSelected: Bool
    let height: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.historyCard, style: .continuous)
        ZStack {
            shape.fill(Color(nsColor: Tokens.Palette.hudControlFill))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: height * aspect, height: height)
        .clipShape(shape)
        .overlay {
            if isSelected {
                shape
                    .inset(by: -Tokens.Stroke.selectionRing)
                    .strokeBorder(Color.accentColor, lineWidth: Tokens.Stroke.selectionRing)
            }
        }
        .dsShadow(Tokens.Shadow.floatingCard)
        .opacity(isSelected ? 1 : 0.8)
        .contentShape(shape)
    }

    private var aspect: CGFloat { Self.aspect(of: item) }

    /// Card width / height, clamped for very tall or wide captures.
    static func aspect(of item: HistoryItem) -> CGFloat {
        guard item.pixelHeight > 0, item.pixelWidth > 0 else { return 1.6 }
        let raw = CGFloat(item.pixelWidth) / CGFloat(item.pixelHeight)
        return min(max(raw, Tokens.History.minAspect), Tokens.History.maxAspect)
    }
}
