import AppKit
import CoreGraphics
import Foundation
import HakoKit
import os

/// Runs the OCR/QR capture flow after a `.captureText` selection (plan
/// §4.13, §7 WP3.5): barcode first; if none found, recognize text; copy the
/// result to the clipboard as plain text; show a toast. Nothing found →
/// "No text found".
///
/// **Entegrasyon parçası** (not wired here — plan §7 WP3.I): the coordinator
/// adds a `.captureText(lineBreaks: Bool)` `AppCommand`, opens the area
/// overlay the same way `.captureArea` does, and on a non-cancelled
/// `SelectionOutcome` captures the rect into a `CaptureResult` and calls
/// `await TextCaptureFlow.handle(result, lineBreaks: lineBreaks)` — this
/// flow does not save to disk or route through `PostCaptureRouter`, and it
/// never touches `ClipboardWriter` (image pasteboard writer); it writes
/// plain text itself. Two menu/shortcut entries per plan §4.13: "Capture
/// Text" (`lineBreaks: true`, default) and "Capture Text Without Line
/// Breaks" (`lineBreaks: false`).
enum TextCaptureFlow {
    private static let log = Logger(subsystem: "com.hakanyucel.HakoShot", category: "ocr")

    static func handle(_ result: CaptureResult, lineBreaks: Bool) async {
        do {
            if let barcode = try await QRDetector.detectFirst(in: result.image) {
                log.notice("captureText: barcode found, payload copied")
                copyPlainText(barcode.payload)
                ToastHUD.show(.linkCopied(url: barcode.url))
                return
            }
        } catch {
            log.error("captureText: barcode detection failed: \(error.localizedDescription, privacy: .public)")
        }

        do {
            let text = try await TextRecognitionService.recognizeText(in: result.image, lineBreaks: lineBreaks)
            if text.isEmpty {
                log.notice("captureText: no text found")
                ToastHUD.show(.message("No text found"))
            } else {
                log.notice("captureText: \(text.count, privacy: .public) character(s) copied")
                copyPlainText(text)
                ToastHUD.show(.commandV)
            }
        } catch {
            log.error("captureText: text recognition failed: \(error.localizedDescription, privacy: .public)")
            ToastHUD.show(.message("No text found"))
        }
    }

    /// Writes plain text to the general pasteboard. Distinct from
    /// `ClipboardWriter` (PostCapture/), which writes PNG/TIFF image data —
    /// `TextCaptureFlow` never writes the captured image to the clipboard.
    private static func copyPlainText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
