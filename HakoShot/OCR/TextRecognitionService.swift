import CoreGraphics
import Foundation
import HakoKit
import os
import Vision

/// Recognizes text in a captured image via the Swift Vision API and
/// assembles it into reading order (plan §1.4, §4.13, §7 WP3.5).
enum TextRecognitionService {
    private static let log = Logger(subsystem: "com.hakanyucel.HakoShot", category: "ocr")

    /// `RecognizeTextRequest().supportedRecognitionLanguages`, as BCP-47
    /// minimal identifiers (e.g. `"tr"`, `"en-US"`). Computed fresh each call
    /// (Vision reports this instantly, no model download involved) so tests
    /// can assert on it directly instead of scraping logs.
    static var supportedRecognitionLanguageIdentifiers: [String] {
        RecognizeTextRequest().supportedRecognitionLanguages.map(\.minimalIdentifier)
    }

    /// Whether Turkish is in `supportedRecognitionLanguageIdentifiers` (plan
    /// §1.4: "Türkçe yoksa fallback VisionKit `ImageAnalyzer`"). On this SDK
    /// (macOS 26.5) it is — see `TextRecognitionServiceTests`.
    static var supportsTurkish: Bool {
        RecognizeTextRequest().supportedRecognitionLanguages.contains { $0.languageCode?.identifier == "tr" }
    }

    /// `recognitionLanguages` hints for `RecognizeTextRequest` (M7 OCR fix;
    /// WP3.I-A finding: relying purely on `automaticallyDetectsLanguage` drops
    /// Turkish diacritics on some captures, e.g. "Çağrı" → "Cagri", at smaller
    /// font sizes). Built from `Locale.preferredLanguages` (System Settings >
    /// Language & Region order) — each entry mapped down to whichever
    /// `supportedRecognitionLanguageIdentifiers` entry matches it (exact
    /// identifier first, e.g. `"zh-TW"`, else the bare language code, e.g.
    /// `"tr"`) — so the device's actual language preferences win. Falls back
    /// to `["tr-TR", "en-US"]` (this app's two real-world languages) when none
    /// of the user's preferred languages are in the supported set.
    static var preferredRecognitionLanguages: [Locale.Language] {
        let supported = Set(supportedRecognitionLanguageIdentifiers)
        var matched: [Locale.Language] = []
        var seen = Set<String>()
        for identifier in Locale.preferredLanguages {
            var candidates = [identifier]
            if let code = Locale.Language(identifier: identifier).languageCode?.identifier {
                candidates.append(code)
            }
            for candidate in candidates where supported.contains(candidate) {
                guard !seen.contains(candidate) else { break }
                matched.append(Locale.Language(identifier: candidate))
                seen.insert(candidate)
                break
            }
        }
        guard matched.isEmpty else { return matched }
        return [Locale.Language(identifier: "tr-TR"), Locale.Language(identifier: "en-US")]
    }

    /// Logged once at first use (plan §1.4: "Açılışta … loglanır").
    private static let logSupportedLanguagesOnce: Void = {
        let identifiers = supportedRecognitionLanguageIdentifiers
        log.notice("supportedRecognitionLanguages (\(identifiers.count)): \(identifiers.joined(separator: ", "), privacy: .public)")
        log.notice("Turkish (tr) supported: \(supportsTurkish, privacy: .public)")
    }()

    /// Recognizes text in `image` and returns it assembled in reading order.
    /// Returns `""` when no text is found. `recognitionLevel = .accurate`,
    /// automatic language detection, language correction on (plan §1.4).
    static func recognizeText(in image: CGImage, lineBreaks: Bool) async throws -> String {
        _ = logSupportedLanguagesOnce

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Automatic detection stays on (harmless empirically — see
        // `TextRecognitionServiceTests`) but `recognitionLanguages` gives it
        // a concrete hint so it doesn't have to guess Turkish vs. English
        // purely from glyph shapes at small font sizes.
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = preferredRecognitionLanguages
        request.usesLanguageCorrection = true

        let results = try await request.perform(on: image)
        log.debug("recognizeText: \(results.count) line observation(s)")

        let observations = results.compactMap { observation -> OCRTextObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let minX = min(observation.topLeft.x, observation.bottomLeft.x)
            let maxX = max(observation.topRight.x, observation.bottomRight.x)
            let minY = min(observation.bottomLeft.y, observation.bottomRight.y)
            let maxY = max(observation.topLeft.y, observation.topRight.y)
            let box = CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
            return OCRTextObservation(text: candidate.string, boundingBox: box, confidence: candidate.confidence)
        }

        return TextLineAssembler.assemble(observations, lineBreaks: lineBreaks)
    }
}
