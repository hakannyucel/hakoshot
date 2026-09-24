import Foundation
import Testing
@testable import HakoShot

/// Runs real Vision recognition against CoreText-rendered fixtures (plan §7
/// WP3.5). OCR isn't pixel-perfect, so assertions use case-insensitive
/// `contains` rather than exact equality.
@Suite("TextRecognitionService")
struct TextRecognitionServiceTests {
    @Test("English and Turkish text is recognized; supportedRecognitionLanguages includes Turkish")
    func recognizesEnglishAndTurkish() async throws {
        // plan §1.4: confirm Turkish is in RecognizeTextRequest's supported list
        // on this OS (macOS 26.5 SDK) rather than needing the VisionKit fallback.
        #expect(TextRecognitionService.supportsTurkish)
        #expect(TextRecognitionService.supportedRecognitionLanguageIdentifiers.contains { $0.hasPrefix("tr") })

        let image = OCRFixture.textImage(lines: [
            "The quick brown fox jumps",
            "Çağrı İşığı Şöyle",
        ])
        let text = try await TextRecognitionService.recognizeText(in: image, lineBreaks: true)
        let lowered = text.lowercased()

        #expect(lowered.contains("quick brown fox"))
        // Case folding can round-trip İ/I differently across locales, so
        // match on a run of the distinctive lowercase Turkish letters instead
        // of the exact original casing.
        #expect(lowered.contains("ağrı") || lowered.contains("cagri") || lowered.contains("çağrı"))
        #expect(text.contains("\n"), "lineBreaks: true should keep the two source lines separate")
    }

    @Test("Turkish diacritics survive at 40pt (WP3.I-A finding, M7 fix)")
    func turkishDiacriticsSurviveAt40pt() async throws {
        let image = OCRFixture.textImage(lines: [
            "The quick brown fox jumps",
            "Çağrı İşığı Şöyle",
        ], fontSize: 40)
        let text = try await TextRecognitionService.recognizeText(in: image, lineBreaks: true)
        #expect(text.lowercased().contains("quick brown fox"))
        #expect(text.contains("Çağrı") || text.contains("çağrı"))
        #expect(text.contains("Şöyle") || text.contains("şöyle"))
    }

    @Test("Turkish diacritics survive at 28pt (WP3.I-A finding, M7 fix)")
    func turkishDiacriticsSurviveAt28pt() async throws {
        let image = OCRFixture.textImage(lines: [
            "The quick brown fox jumps",
            "Çağrı İşığı Şöyle",
        ], fontSize: 28)
        let text = try await TextRecognitionService.recognizeText(in: image, lineBreaks: true)
        #expect(text.lowercased().contains("quick brown fox"))
        #expect(text.contains("Çağrı") || text.contains("çağrı"))
        #expect(text.contains("Şöyle") || text.contains("şöyle"))
    }

    @Test("preferredRecognitionLanguages falls back to tr-TR/en-US when nothing matches")
    func preferredRecognitionLanguagesFallback() {
        // Real `Locale.preferredLanguages` on the test machine almost always
        // includes "en", which is always in `supportedRecognitionLanguageIdentifiers`,
        // so this only asserts the shape of the fallback contract, not that
        // it necessarily triggers on this machine: every returned language's
        // minimal identifier must be one Vision actually supports.
        let supported = Set(TextRecognitionService.supportedRecognitionLanguageIdentifiers)
        let languages = TextRecognitionService.preferredRecognitionLanguages
        #expect(!languages.isEmpty)
        for language in languages {
            #expect(supported.contains(language.minimalIdentifier))
        }
    }

    @Test("lineBreaks: false joins recognized lines with spaces, no newlines")
    func joinsWithoutLineBreaks() async throws {
        let image = OCRFixture.textImage(lines: ["First line here", "Second line here"])
        let text = try await TextRecognitionService.recognizeText(in: image, lineBreaks: false)

        #expect(!text.contains("\n"))
        let lowered = text.lowercased()
        #expect(lowered.contains("first line"))
        #expect(lowered.contains("second line"))
    }

    @Test("a blank image yields no recognized text")
    func blankImageYieldsEmptyString() async throws {
        let blank = OCRFixture.textImage(lines: [], width: 200)
        let text = try await TextRecognitionService.recognizeText(in: blank, lineBreaks: true)
        #expect(text.isEmpty)
    }
}
