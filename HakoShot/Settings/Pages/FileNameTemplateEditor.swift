import AppKit
import HakoKit
import SwiftUI

/// Modal file name format editor (plan §5.3 Advanced "Edit…", report §12
/// `settings14.png`): the pattern as chips (tokens) and editable text pieces.
/// Chips can be dragged to reorder; palette chips are clicked to append or
/// dragged onto a chip to insert before it. Live preview underneath.
struct FileNameTemplateEditor: View {
    @Binding var pattern: String
    let format: ImageFormat
    let counter: Int
    @Environment(\.dismiss) private var dismiss

    @State private var segments: [FileNameSegment]
    @State private var newText = ""

    /// Pattern suggestions (plan §5.4 default + M7 acceptance #3 example).
    private static let presets: [(title: String, pattern: String)] = [
        ("Default", FileNameTemplate.default.pattern),
        ("Date and number", "%Y%m%d-%n"),
        ("Mode and time", "%mode %Y-%m-%d %H.%M.%S"),
        ("12-hour clock", "HakoShot %Y-%m-%d at %h.%M.%S %p"),
        ("Month name", "HakoShot %d %B %Y at %H.%M"),
    ]

    init(pattern: Binding<String>, format: ImageFormat, counter: Int) {
        _pattern = pattern
        self.format = format
        self.counter = counter
        _segments = State(initialValue: FileNamePatternParser.segments(from: pattern.wrappedValue))
    }

    private var currentPattern: String { FileNamePatternParser.pattern(from: segments) }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text("File name format").font(.headline)
                Text("Drag chips to reorder, click a variable below to add it, or type text between them.")
                    .font(Tokens.Typography.rowDescription)
                    .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
            }

            chipField

            HStack(spacing: Tokens.Spacing.xs) {
                Text("Preview:").foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                Text(FileNamePreview.fileName(pattern: currentPattern, format: format, counter: counter))
                    .fontWeight(.medium)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Tokens.Typography.rowLabel)

            VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
                paletteRow("Date", FileNameToken.dateTokens)
                paletteRow("Time", FileNameToken.timeTokens)
                paletteRow("Other", FileNameToken.otherTokens, includesSpace: true)
            }

            HStack(spacing: Tokens.Spacing.s) {
                Text("Pattern").foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                TextField("Pattern", text: patternTextBinding)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                Menu("Presets") {
                    ForEach(Self.presets, id: \.pattern) { preset in
                        Button(preset.title) { segments = FileNamePatternParser.segments(from: preset.pattern) }
                    }
                }
                .fixedSize()
            }
            .font(Tokens.Typography.rowLabel)

            HStack {
                Button("Reset to Default") { segments = FileNamePatternParser.segments(from: FileNameTemplate.default.pattern) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") {
                    let result = FileNamePatternParser.pattern(from: FileNamePatternParser.normalized(segments))
                    pattern = result.trimmingCharacters(in: .whitespaces).isEmpty ? FileNameTemplate.default.pattern : result
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Tokens.Spacing.xl)
        .frame(width: SettingsMetrics.modalWidth)
    }

    // MARK: Chip field

    private var chipField: some View {
        FlowLayout(spacing: Tokens.Spacing.xs) {
            ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                segmentChip(segment, at: index)
                    .dropDestination(for: String.self) { items, _ in
                        return handleDrop(items, before: index)
                    }
            }
            TextField("Add text", text: $newText)
                .textFieldStyle(.plain)
                .frame(minWidth: 70)
                .fixedSize()
                .frame(height: SettingsMetrics.chipHeight)
                .onSubmit(appendNewText)
                .dropDestination(for: String.self) { items, _ in
                    return handleDrop(items, before: segments.count)
                }
        }
        .padding(Tokens.Spacing.s)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor))
                .overlay {
                    RoundedRectangle(cornerRadius: Tokens.Radius.toolHighlight, style: .continuous)
                        .strokeBorder(Color.dsDivider, lineWidth: Tokens.Stroke.hairline)
                }
        }
        .dropDestination(for: String.self) { items, _ in
            return handleDrop(items, before: segments.count)
        }
    }

    @ViewBuilder
    private func segmentChip(_ segment: FileNameSegment, at index: Int) -> some View {
        switch segment {
        case let .token(token):
            tokenChip(token.title, help: token.rawValue, payload: DragPayload.segment(index)) {
                segments.remove(at: index)
            }
        case let .text(text) where !text.isEmpty && text.allSatisfy({ $0 == " " }):
            tokenChip(text.count == 1 ? "Space" : "\(text.count) Spaces", help: "Space", payload: DragPayload.segment(index)) {
                segments.remove(at: index)
            }
        case let .text(text):
            TextField("text", text: textBinding(at: index, fallback: text))
                .textFieldStyle(.plain)
                .fixedSize()
                .padding(.horizontal, Tokens.Spacing.xxs)
                .frame(height: SettingsMetrics.chipHeight)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.swatchSmall / 2)
                        .fill(Color.primary.opacity(0.05))
                }
                .accessibilityLabel("Text")
        }
    }

    private func tokenChip(_ title: String, help: String, payload: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(title)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Remove \(title)")
        }
        .font(Tokens.Typography.rowLabel)
        .padding(.horizontal, SettingsMetrics.chipPaddingH)
        .frame(height: SettingsMetrics.chipHeight)
        .background(Capsule().fill(SettingsMetrics.chipFill))
        .help(help)
        .draggable(payload)
    }

    private func paletteRow(_ title: String, _ tokens: [FileNameToken], includesSpace: Bool = false) -> some View {
        HStack(spacing: Tokens.Spacing.s) {
            Text(title)
                .font(Tokens.Typography.rowDescription)
                .foregroundStyle(Color(nsColor: Tokens.Palette.textSecondary))
                .frame(width: 40, alignment: .leading)
            ForEach(tokens, id: \.self) { token in
                Button {
                    segments.append(.token(token))
                } label: {
                    Text(token.title)
                        .font(Tokens.Typography.rowLabel)
                        .padding(.horizontal, SettingsMetrics.chipPaddingH)
                        .frame(height: SettingsMetrics.chipHeight)
                        .background(Capsule().fill(SettingsMetrics.chipFill))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(token.rawValue): \(FileNamePreview.sample(for: token, counter: counter))")
                .draggable(DragPayload.token(token))
            }
            if includesSpace {
                Button {
                    segments.append(.text(" "))
                } label: {
                    Text("Space")
                        .font(Tokens.Typography.rowLabel)
                        .padding(.horizontal, SettingsMetrics.chipPaddingH)
                        .frame(height: SettingsMetrics.chipHeight)
                        .background(Capsule().strokeBorder(SettingsMetrics.chipFill, lineWidth: Tokens.Stroke.hairline * 1.5))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("A space between two variables")
            }
        }
    }

    // MARK: Editing

    private func textBinding(at index: Int, fallback: String) -> Binding<String> {
        Binding(
            get: {
                guard segments.indices.contains(index), case let .text(text) = segments[index] else { return fallback }
                return text
            },
            set: { newValue in
                guard segments.indices.contains(index) else { return }
                segments[index] = .text(newValue)
            }
        )
    }

    private var patternTextBinding: Binding<String> {
        Binding(
            get: { currentPattern },
            set: { segments = FileNamePatternParser.segments(from: $0) }
        )
    }

    private func appendNewText() {
        guard !newText.isEmpty else { return }
        segments = FileNamePatternParser.normalized(segments + [.text(newText)])
        newText = ""
    }

    private func handleDrop(_ items: [String], before index: Int) -> Bool {
        guard let item = items.first, let payload = DragPayload(item) else { return false }
        switch payload {
        case let .segment(source):
            segments = FileNamePatternParser.moving(segments, from: source, to: index)
        case let .token(token):
            segments.insert(.token(token), at: min(max(index, 0), segments.count))
        }
        return true
    }
}

/// Drag payload between chips (plain strings keep it `Transferable`).
private enum DragPayload {
    case segment(Int)
    case token(FileNameToken)

    init?(_ string: String) {
        if string.hasPrefix("hakoshot-seg:"), let index = Int(string.dropFirst("hakoshot-seg:".count)) {
            self = .segment(index)
        } else if string.hasPrefix("hakoshot-tok:"), let token = FileNameToken(rawValue: String(string.dropFirst("hakoshot-tok:".count))) {
            self = .token(token)
        } else {
            return nil
        }
    }

    static func segment(_ index: Int) -> String { "hakoshot-seg:\(index)" }
    static func token(_ token: FileNameToken) -> String { "hakoshot-tok:\(token.rawValue)" }
}

/// Example file names for the Advanced page and the chip editor.
enum FileNamePreview {
    static func fileName(pattern: String, format: ImageFormat, counter: Int, mode: String = "area", date: Date = .now) -> String {
        FileNamer(template: FileNameTemplate(pattern: pattern), pathExtension: format.fileExtension, clock: { date })
            .fileName(counter: counter, mode: mode)
    }

    /// What one token renders to right now.
    static func sample(for token: FileNameToken, counter: Int) -> String {
        FileNameTemplate(pattern: token.rawValue)
            .render(context: FileNameContext(date: .now, counter: counter, mode: "area"))
    }
}

/// Left-to-right wrapping layout for chips.
struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(subviews, width: bounds.width)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: bounds.minY + row.y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                let nextY = current.y + current.height + spacing
                rows.append(current)
                current = Row(y: nextY)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
