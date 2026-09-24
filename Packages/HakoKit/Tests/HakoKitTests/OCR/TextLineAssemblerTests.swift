import CoreGraphics
import Testing
@testable import HakoKit

/// Fake observations only — no Vision here (that's `TextRecognitionServiceTests`
/// in the app target). Coordinates follow Vision's normalized convention:
/// origin bottom-left, y increasing upward, 0...1 on both axes.
@Suite("TextLineAssembler")
struct TextLineAssemblerTests {
    /// A normalized line box at row `row` (0 = top row) of a `rows`-line
    /// single-column block, spanning `xRange` horizontally.
    private func box(row: Int, of rows: Int, xRange: ClosedRange<CGFloat> = 0.1...0.5, lineHeight: CGFloat = 0.08) -> CGRect {
        let top = 0.95 - CGFloat(row) * lineHeight
        return CGRect(x: xRange.lowerBound, y: top - lineHeight * 0.8, width: xRange.upperBound - xRange.lowerBound, height: lineHeight * 0.8)
    }

    @Test("orders shuffled single-column lines top to bottom")
    func singleColumnReadingOrder() {
        let observations = [
            OCRTextObservation(text: "third", boundingBox: box(row: 2, of: 3)),
            OCRTextObservation(text: "first", boundingBox: box(row: 0, of: 3)),
            OCRTextObservation(text: "second", boundingBox: box(row: 1, of: 3)),
        ]
        #expect(TextLineAssembler.assemble(observations, lineBreaks: true) == "first\nsecond\nthird")
        #expect(TextLineAssembler.assemble(observations, lineBreaks: false) == "first second third")
    }

    @Test("drops blank/whitespace-only observations")
    func dropsBlankObservations() {
        let observations = [
            OCRTextObservation(text: "first", boundingBox: box(row: 0, of: 2)),
            OCRTextObservation(text: "   ", boundingBox: box(row: 1, of: 2)),
        ]
        #expect(TextLineAssembler.assemble(observations, lineBreaks: true) == "first")
    }

    @Test("empty input produces empty string")
    func emptyInput() {
        #expect(TextLineAssembler.assemble([], lineBreaks: true) == "")
        #expect(TextLineAssembler.assemble([], lineBreaks: false) == "")
    }

    @Test("two non-overlapping columns: left column fully before right column")
    func multiColumn() {
        // Left column: x in 0.05...0.35; right column: x in 0.6...0.9 (no overlap).
        // Same rows (normal single-line spacing) so the only break is the column change.
        let leftTop = OCRTextObservation(text: "L1", boundingBox: box(row: 0, of: 2, xRange: 0.05...0.35))
        let leftBottom = OCRTextObservation(text: "L2", boundingBox: box(row: 1, of: 2, xRange: 0.05...0.35))
        let rightTop = OCRTextObservation(text: "R1", boundingBox: box(row: 0, of: 2, xRange: 0.6...0.9))
        let rightBottom = OCRTextObservation(text: "R2", boundingBox: box(row: 1, of: 2, xRange: 0.6...0.9))
        // Shuffled input order.
        let observations = [rightBottom, leftTop, rightTop, leftBottom]
        let result = TextLineAssembler.assemble(observations, lineBreaks: true)
        #expect(result == "L1\nL2\n\nR1\nR2")
    }

    @Test("large vertical gap within a column reads as a paragraph break")
    func paragraphBreak() {
        let line1 = OCRTextObservation(text: "Paragraph one, line one.", boundingBox: CGRect(x: 0.1, y: 0.90, width: 0.5, height: 0.06))
        let line2 = OCRTextObservation(text: "Paragraph one, line two.", boundingBox: CGRect(x: 0.1, y: 0.83, width: 0.5, height: 0.06))
        // Gap to line3 is much larger than the gap between line1/line2.
        let line3 = OCRTextObservation(text: "Paragraph two.", boundingBox: CGRect(x: 0.1, y: 0.60, width: 0.5, height: 0.06))
        let result = TextLineAssembler.assemble([line3, line1, line2], lineBreaks: true)
        #expect(result == "Paragraph one, line one.\nParagraph one, line two.\n\nParagraph two.")
    }

    @Test("paragraph breaks collapse to single spaces when lineBreaks is false")
    func paragraphBreaksCollapseWithoutLineBreaks() {
        let line1 = OCRTextObservation(text: "Paragraph one.", boundingBox: CGRect(x: 0.1, y: 0.90, width: 0.5, height: 0.06))
        let line2 = OCRTextObservation(text: "Paragraph two.", boundingBox: CGRect(x: 0.1, y: 0.60, width: 0.5, height: 0.06))
        let result = TextLineAssembler.assemble([line2, line1], lineBreaks: false)
        #expect(result == "Paragraph one. Paragraph two.")
    }

    @Test("normal single-line spacing does not trigger a paragraph break")
    func normalSpacingNoBreak() {
        let observations = (0..<5).map { row in
            OCRTextObservation(text: "line\(row)", boundingBox: box(row: row, of: 5))
        }.shuffled()
        let result = TextLineAssembler.assemble(observations, lineBreaks: true)
        #expect(result == "line0\nline1\nline2\nline3\nline4")
    }
}
