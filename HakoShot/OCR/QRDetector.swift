import CoreGraphics
import Foundation
import os
import Vision

/// Detects 2D barcodes (QR, Aztec, Data Matrix, PDF417) via the Swift Vision
/// API (plan §1.4, §4.13, §7 WP3.5).
enum QRDetector {
    private static let log = Logger(subsystem: "com.hakanyucel.HakoShot", category: "ocr")

    /// One decoded barcode's payload.
    struct Result: Sendable, Equatable {
        var payload: String
        /// `true` when `payload` parses as an `http`/`https` URL (plan §4.13:
        /// "payload URL ise toast'ta 'Open' butonu").
        var url: URL?

        init(payload: String) {
            self.payload = payload
            if let url = URL(string: payload), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
                self.url = url
            } else {
                self.url = nil
            }
        }
    }

    /// Detects barcodes in `image` and returns the first one with a string
    /// payload, or `nil` if none are found (plan §4.13 runs this before OCR).
    static func detectFirst(in image: CGImage) async throws -> Result? {
        var request = DetectBarcodesRequest()
        request.symbologies = [.qr, .aztec, .dataMatrix, .pdf417]

        let results = try await request.perform(on: image)
        log.debug("detectFirst: \(results.count) barcode observation(s)")

        guard let payload = results.compactMap(\.payloadString).first else { return nil }
        return Result(payload: payload)
    }
}
