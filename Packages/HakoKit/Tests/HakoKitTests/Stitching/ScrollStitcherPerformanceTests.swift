import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

#if DEBUG
private let isReleaseBuild = false
#else
private let isReleaseBuild = true
#endif

@Suite("ScrollStitcher performance")
struct ScrollStitcherPerformanceTests {
    /// Plan §7 WP6.1: a 10,000 px synthetic page stitches in under 1 s in a
    /// release build (`swift test -c release --filter StitchPerf`).
    /// Skipped in debug builds (unoptimized pixel loops take ~10 s there).
    @Test(.enabled(if: isReleaseBuild, "timing is only meaningful in release"))
    func stitchPerfTenThousandPixelPage() throws {
        var rng = FixtureRNG(seed: 2026)
        let page = Fixture.page(width: 1200, height: 10_000, seed: 2026)
        let frameHeight = 800
        let offsets = Fixture.offsets(last: page.height - frameHeight, steps: 220...320, rng: &rng)
        let images = offsets.map { Fixture.image(Fixture.frame(page: page, offset: $0, height: frameHeight, rng: &rng)) }

        let clock = ContinuousClock()
        var stitcher = ScrollStitcher()
        var result: CGImage?
        let elapsed = clock.measure {
            for image in images { _ = stitcher.append(image) }
            result = stitcher.makeImage()
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("ScrollStitcher: \(images.count) frames of 1200x\(frameHeight) → 1200x\(page.height) in \(String(format: "%.3f", seconds)) s")

        let stitched = try #require(result.flatMap(Fixture.pixels(of:)))
        #expect(stitched == page)
        #expect(seconds < 1)
    }
}
