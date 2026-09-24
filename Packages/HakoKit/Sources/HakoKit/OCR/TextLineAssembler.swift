import CoreGraphics
import Foundation

/// One recognized line of text, as `TextLineAssembler` needs it.
///
/// Decoupled from Vision's own `RecognizedTextObservation` so HakoKit never
/// imports Vision and tests can build fake observations directly (plan §7
/// WP3.5). `RecognizeTextRequest` already returns one observation per
/// detected *line* of text (see `RecognizedText`/`topCandidates`), so this
/// type — like Vision's — is line-granularity, not word-granularity.
///
/// `boundingBox` is normalized (0...1 on each axis) in Vision's own
/// convention: origin bottom-left, y increasing upward (`NormalizedPoint`'s
/// default `.lowerLeft` image-coordinate origin) — the same convention
/// `TextRecognitionService` reads off `topLeft`/`topRight`/`bottomLeft`/
/// `bottomRight`.
public struct OCRTextObservation: Sendable, Equatable {
    public var text: String
    public var boundingBox: CGRect
    public var confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float = 1) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

/// Assembles Vision text-line observations into reading order (plan §4.13,
/// §7 WP3.5). Vision returns one observation per line already, in no defined
/// order, so this reorders top-to-bottom, and — roughly — left column before
/// right column for multi-column layouts, then joins the lines.
public enum TextLineAssembler {
    /// - Parameters:
    ///   - observations: one per recognized text line.
    ///   - lineBreaks: `true` keeps line breaks (and a blank line between
    ///     paragraphs, i.e. lines separated by an unusually large vertical
    ///     gap); `false` joins every line into a single line separated by
    ///     one space (plan §4.13: "tek boşlukla birleştirilir").
    public static func assemble(_ observations: [OCRTextObservation], lineBreaks: Bool) -> String {
        let lines = orderedLines(observations)
        guard !lines.isEmpty else { return "" }
        if !lineBreaks {
            return lines.map(\.text).joined(separator: " ")
        }
        return joinedPreservingParagraphs(lines)
    }

    // MARK: - Ordering

    struct OrderedLine {
        var text: String
        var boundingBox: CGRect
        var column: Int
    }

    /// Trims/drops empty observations, clusters into columns, and sorts each
    /// column top-to-bottom; columns are ordered left-to-right.
    static func orderedLines(_ observations: [OCRTextObservation]) -> [OrderedLine] {
        let trimmed = observations
            .map { OCRTextObservation(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), boundingBox: $0.boundingBox, confidence: $0.confidence) }
            .filter { !$0.text.isEmpty }
        guard !trimmed.isEmpty else { return [] }

        var result: [OrderedLine] = []
        for (index, column) in clusterColumns(trimmed).enumerated() {
            let sorted = column.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
            result.append(contentsOf: sorted.map { OrderedLine(text: $0.text, boundingBox: $0.boundingBox, column: index) })
        }
        return result
    }

    /// Greedy clustering by horizontal-range overlap — a rough approximation
    /// of column layout (plan §7 WP3.5: "multi-column roughly"). A normal
    /// single-column paragraph's lines all overlap near the same left
    /// margin and merge into one cluster; genuinely side-by-side text blocks
    /// (no horizontal overlap) split into separate clusters, returned
    /// left-to-right.
    static func clusterColumns(_ observations: [OCRTextObservation]) -> [[OCRTextObservation]] {
        struct Cluster {
            var minX: CGFloat
            var maxX: CGFloat
            var items: [OCRTextObservation]
        }
        var clusters: [Cluster] = []
        for observation in observations.sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
            let box = observation.boundingBox
            if let index = clusters.firstIndex(where: { horizontallyOverlaps($0.minX, $0.maxX, box.minX, box.maxX) }) {
                clusters[index].items.append(observation)
                clusters[index].minX = min(clusters[index].minX, box.minX)
                clusters[index].maxX = max(clusters[index].maxX, box.maxX)
            } else {
                clusters.append(Cluster(minX: box.minX, maxX: box.maxX, items: [observation]))
            }
        }
        return clusters.sorted { $0.minX < $1.minX }.map(\.items)
    }

    private static func horizontallyOverlaps(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> Bool {
        aMin <= bMax && bMin <= aMax
    }

    // MARK: - Joining

    /// Joins ordered lines with `\n`, inserting a blank line where the
    /// vertical gap between two consecutive lines of the same column is
    /// clearly larger than normal single-line spacing (a paragraph break),
    /// or where the column changes.
    private static func joinedPreservingParagraphs(_ lines: [OrderedLine]) -> String {
        var parts: [String] = []
        var previous: OrderedLine?
        for line in lines {
            if let previous {
                if previous.column != line.column {
                    parts.append("")
                } else {
                    let gap = previous.boundingBox.minY - line.boundingBox.maxY
                    let lineHeight = max(previous.boundingBox.height, line.boundingBox.height, 0.0001)
                    if gap > lineHeight * 0.9 {
                        parts.append("")
                    }
                }
            }
            parts.append(line.text)
            previous = line
        }
        return parts.joined(separator: "\n")
    }
}
