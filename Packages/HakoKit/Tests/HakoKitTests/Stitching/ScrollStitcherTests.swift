import CoreGraphics
import Foundation
import Testing
@testable import HakoKit

@Suite("ScrollStitcher")
struct ScrollStitcherTests {
    /// Stitches `frames`, returns events and the final pixels.
    static func run(_ frames: [StitchPixels], configuration: ScrollStitcherConfiguration = .init(),
                    hints: [Int?]? = nil) -> (events: [StitchEvent], result: StitchPixels?) {
        var stitcher = ScrollStitcher(configuration: configuration)
        var events: [StitchEvent] = []
        for (i, frame) in frames.enumerated() {
            events.append(stitcher.append(Fixture.image(frame), expectedDelta: hints?[i] ?? nil))
        }
        return (events, stitcher.makeImage().flatMap(Fixture.pixels(of:)))
    }

    static func appendedCount(_ events: [StitchEvent]) -> Int {
        events.filter { if case .appended = $0 { true } else { false } }.count
    }

    @Test(arguments: [UInt64(1), 2, 3, 4])
    func plainVertical(seed: UInt64) throws {
        var rng = FixtureRNG(seed: seed &* 31)
        let page = Fixture.page(width: 480, height: 3200, seed: seed)
        let frameHeight = 420
        let offsets = Fixture.offsets(last: page.height - frameHeight, steps: 40...330, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: frameHeight, rng: &rng) }
        let (events, result) = Self.run(frames, configuration: .init(axis: .vertical))
        #expect(events.first == .started)
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        let stitched = try #require(result)
        #expect(stitched == page)
    }

    @Test func automaticAxisPicksVertical() throws {
        var rng = FixtureRNG(seed: 99)
        let page = Fixture.page(width: 500, height: 2000, seed: 17)
        let offsets = Fixture.offsets(last: page.height - 400, steps: 100...250, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: 400, rng: &rng) }
        var stitcher = ScrollStitcher()
        for f in frames { _ = stitcher.append(Fixture.image(f)) }
        #expect(stitcher.axis == .vertical)
        let stitched = try #require(stitcher.makeImage().flatMap(Fixture.pixels(of:)))
        #expect(stitched == page)
    }

    @Test(arguments: [StitchAxis?.none, .horizontal])
    func horizontal(axis: StitchAxis?) throws {
        var rng = FixtureRNG(seed: 7)
        // A tall page transposed = a wide page; frames are column slices.
        let tall = Fixture.page(width: 360, height: 2600, seed: 8)
        let wide = tall.transposed()
        let frameWidth = 500
        let offsets = Fixture.offsets(last: tall.height - frameWidth, steps: 60...300, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: tall, offset: $0, height: frameWidth, rng: &rng).transposed() }
        var stitcher = ScrollStitcher(configuration: .init(axis: axis))
        var events: [StitchEvent] = []
        for f in frames { events.append(stitcher.append(Fixture.image(f))) }
        #expect(stitcher.axis == .horizontal)
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        let stitched = try #require(stitcher.makeImage().flatMap(Fixture.pixels(of:)))
        #expect(stitched.width == wide.width && stitched.height == wide.height)
        #expect(stitched == wide)
    }

    @Test(arguments: [UInt64(11), 12, 13])
    func stickyHeaderAndFooter(seed: UInt64) throws {
        var rng = FixtureRNG(seed: seed)
        let width = 520
        let page = Fixture.page(width: width, height: 3000, seed: seed)
        let header = Fixture.band(width: width, height: 64, seed: seed + 100, base: (40, 70, 160))
        let footer = Fixture.band(width: width, height: 44, seed: seed + 200, base: (30, 30, 30))
        let frameHeight = 480
        let content = frameHeight - header.height - footer.height
        let offsets = Fixture.offsets(last: page.height - content, steps: 30...250, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: frameHeight, header: header, footer: footer, rng: &rng) }
        let (events, result) = Self.run(frames)
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        let expected = StitchPixels(width: width, height: header.height + page.height + footer.height,
                                    pixels: header.pixels + page.pixels + footer.pixels)
        let stitched = try #require(result)
        #expect(stitched.height == expected.height)
        #expect(stitched == expected)
    }

    static func repeatingFixture(seed: UInt64) -> (page: StitchPixels, frames: [StitchPixels], deltas: [Int]) {
        var rng = FixtureRNG(seed: seed)
        let options = Fixture.PageOptions(repeatingRegion: 500..<2900, repeatPeriod: 48)
        let page = Fixture.page(width: 400, height: 3400, seed: seed, options: options)
        let frameHeight = 450
        let offsets = Fixture.offsets(last: page.height - frameHeight, steps: 100...300, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: frameHeight, rng: &rng) }
        let deltas = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
        return (page, frames, deltas)
    }

    @Test func repeatingPatternWithHint() throws {
        let (page, frames, deltas) = Self.repeatingFixture(seed: 21)
        var rng = FixtureRNG(seed: 5)
        // Auto-scroll hints are approximate: ±6 px.
        let hints: [Int?] = [nil] + deltas.map { $0 + Int.random(in: -6...6, using: &rng) }
        let (events, result) = Self.run(frames, hints: hints)
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        #expect(events.contains { if case .appended(let s) = $0 { s.ambiguous } else { false } })
        #expect(try #require(result) == page)
    }

    @Test func repeatingPatternWithoutHintReportsAmbiguity() throws {
        let (page, frames, _) = Self.repeatingFixture(seed: 21)
        let (events, result) = Self.run(frames)
        // Offsets inside the pattern cannot be known; the stitcher must say so
        // and fall back to the largest overlap (never longer than the truth).
        #expect(events.contains { if case .appended(let s) = $0 { s.ambiguous } else { false } })
        let stitched = try #require(result)
        #expect(stitched.width == page.width)
        #expect(stitched.height <= page.height)
    }

    @Test(arguments: [UInt64(41), 42, 43])
    func noisyFrames(seed: UInt64) throws {
        var rng = FixtureRNG(seed: seed)
        let page = Fixture.page(width: 480, height: 2600, seed: seed)
        let frameHeight = 420
        let offsets = Fixture.offsets(last: page.height - frameHeight, steps: 60...300, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: frameHeight, noise: 3, rng: &rng) }
        let (events, result) = Self.run(frames, configuration: .init(axis: .vertical))
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        let stitched = try #require(result)
        #expect(stitched.height == page.height)
        #expect(Fixture.meanDifference(stitched, page) < 2.5)
    }

    @Test func blankRegion() throws {
        var rng = FixtureRNG(seed: 51)
        let options = Fixture.PageOptions(blankRegion: 900..<1120)
        let page = Fixture.page(width: 480, height: 2400, seed: 51, options: options)
        let frameHeight = 400
        let offsets = Fixture.offsets(last: page.height - frameHeight, steps: 40...130, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: frameHeight, rng: &rng) }
        let (events, result) = Self.run(frames, configuration: .init(axis: .vertical))
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        #expect(try #require(result) == page)
    }

    @Test func tooFastGapIsRejectedAndRecovers() throws {
        var rng = FixtureRNG(seed: 61)
        let page = Fixture.page(width: 480, height: 2400, seed: 61)
        let h = 400
        let f0 = Fixture.frame(page: page, offset: 0, height: h, rng: &rng)
        let fGap = Fixture.frame(page: page, offset: 900, height: h, rng: &rng)   // no overlap with f0
        let f1 = Fixture.frame(page: page, offset: 250, height: h, rng: &rng)
        let f2 = Fixture.frame(page: page, offset: 500, height: h, rng: &rng)
        var stitcher = ScrollStitcher(configuration: .init(axis: .vertical))
        #expect(stitcher.append(Fixture.image(f0)) == .started)
        let gap = stitcher.append(Fixture.image(fGap))
        #expect(gap == .rejected(.tooFast))
        #expect(gap.suggestsSlowingDown)
        _ = stitcher.append(Fixture.image(f1))
        _ = stitcher.append(Fixture.image(f2))
        let stitched = try #require(stitcher.makeImage().flatMap(Fixture.pixels(of:)))
        #expect(stitched == StitchPixels(width: page.width, height: 900, pixels: Fixture.rows(page, 0..<900)))
    }

    @Test func duplicateFrame() throws {
        var rng = FixtureRNG(seed: 71)
        let page = Fixture.page(width: 480, height: 1500, seed: 71)
        let f0 = Fixture.frame(page: page, offset: 0, height: 400, rng: &rng)
        let f1 = Fixture.frame(page: page, offset: 200, height: 400, rng: &rng)
        var stitcher = ScrollStitcher()
        #expect(stitcher.append(Fixture.image(f0)) == .started)
        #expect(stitcher.append(Fixture.image(f0)) == .duplicate)
        guard case .appended(let step) = stitcher.append(Fixture.image(f1)) else {
            Issue.record("expected appended"); return
        }
        #expect(step.offset == 200)
        #expect(stitcher.append(Fixture.image(f1)) == .duplicate)
        #expect(stitcher.acceptedFrameCount == 2)
        let stitched = try #require(stitcher.makeImage().flatMap(Fixture.pixels(of:)))
        #expect(stitched == StitchPixels(width: 480, height: 600, pixels: Fixture.rows(page, 0..<600)))
    }

    @Test func backwardScrollIsIgnored() throws {
        var rng = FixtureRNG(seed: 81)
        let page = Fixture.page(width: 480, height: 1500, seed: 81)
        let f0 = Fixture.frame(page: page, offset: 300, height: 400, rng: &rng)
        let back = Fixture.frame(page: page, offset: 180, height: 400, rng: &rng)
        let f1 = Fixture.frame(page: page, offset: 450, height: 400, rng: &rng)
        var stitcher = ScrollStitcher(configuration: .init(axis: .vertical))
        _ = stitcher.append(Fixture.image(f0))
        #expect(stitcher.append(Fixture.image(back)) == .rejected(.backward(offset: 120)))
        guard case .appended(let step) = stitcher.append(Fixture.image(f1)) else {
            Issue.record("expected appended"); return
        }
        #expect(step.offset == 150)
        let stitched = try #require(stitcher.makeImage().flatMap(Fixture.pixels(of:)))
        #expect(stitched == StitchPixels(width: 480, height: 550, pixels: Fixture.rows(page, 300..<850)))
    }

    @Test func overlayScrollBarStripIsIgnored() throws {
        var rng = FixtureRNG(seed: 91)
        let page = Fixture.page(width: 480, height: 2000, seed: 91)
        let h = 400
        let offsets = Fixture.offsets(last: page.height - h, steps: 80...250, rng: &rng)
        let frames = offsets.enumerated().map { i, o -> StitchPixels in
            var f = Fixture.frame(page: page, offset: o, height: h, rng: &rng)
            // Scroll bar thumb (only in some frames) in the rightmost 10 px.
            if i % 2 == 1 {
                let top = o * h / page.height
                for y in top..<min(h, top + 60) { for x in (f.width - 10)..<f.width { f.pixels[y * f.width + x] = Fixture.pixel(120, 120, 120) } }
            }
            return f
        }
        let (events, result) = Self.run(frames, configuration: .init(axis: .vertical))
        #expect(Self.appendedCount(events) == frames.count - 1, "\(events)")
        let stitched = try #require(result)
        #expect(stitched.height == page.height)
        #expect(Fixture.meanDifference(stitched, page, ignoringTrailingColumns: 16) == 0)
    }

    @Test func sizeMismatchIsRejected() {
        var rng = FixtureRNG(seed: 1)
        let page = Fixture.page(width: 300, height: 800, seed: 1)
        var stitcher = ScrollStitcher()
        _ = stitcher.append(Fixture.image(Fixture.frame(page: page, offset: 0, height: 300, rng: &rng)))
        #expect(stitcher.append(Fixture.image(Fixture.frame(page: page, offset: 50, height: 280, rng: &rng))) == .rejected(.sizeMismatch))
    }

    @Test func lengthLimit() throws {
        var rng = FixtureRNG(seed: 3)
        let page = Fixture.page(width: 300, height: 3000, seed: 3)
        let offsets = Fixture.offsets(last: page.height - 400, steps: 150...250, rng: &rng)
        let frames = offsets.map { Fixture.frame(page: page, offset: $0, height: 400, rng: &rng) }
        var stitcher = ScrollStitcher(configuration: .init(axis: .vertical, maximumLength: 1000))
        var sawLimit = false
        for f in frames {
            if case .limitReached = stitcher.append(Fixture.image(f)) { sawLimit = true }
        }
        #expect(sawLimit)
        #expect(stitcher.isAtLengthLimit)
        let stitched = try #require(stitcher.makeImage().flatMap(Fixture.pixels(of:)))
        #expect(stitched == StitchPixels(width: 300, height: 1000, pixels: Fixture.rows(page, 0..<1000)))
    }

    @Test func previewThumbnail() throws {
        var rng = FixtureRNG(seed: 4)
        let page = Fixture.page(width: 480, height: 2000, seed: 4)
        let offsets = Fixture.offsets(last: page.height - 400, steps: 150...250, rng: &rng)
        var stitcher = ScrollStitcher(configuration: .init(axis: .vertical))
        #expect(stitcher.previewImage(maxDimension: 200) == nil)
        for o in offsets { _ = stitcher.append(Fixture.image(Fixture.frame(page: page, offset: o, height: 400, rng: &rng))) }
        let preview = try #require(stitcher.previewImage(maxDimension: 200))
        #expect(preview.height == 200)
        #expect(preview.width == 48)
        #expect(stitcher.stitchedPixelSize.width == 480 && stitcher.stitchedPixelSize.height == 2000)
    }
}
