import Foundation

/// A found offset between two consecutive frames.
struct StitchMatch: Sendable, Equatable {
    /// `cur[y] == prev[y + offset]`. Positive = forward scroll.
    var offset: Int
    var confidence: Double
    var ambiguous: Bool
    /// Rows at the top that stayed put in both frames (sticky header).
    var leadingStatic: Int
    /// Rows at the bottom that stayed put in both frames (sticky footer).
    var trailingStatic: Int
}

enum StitchMatchOutcome: Sendable, Equatable {
    case duplicate
    case match(StitchMatch)
    case noMatch
}

/// Offset search between two frames (plan §4.8 steps 2–5).
///
/// Stage 1 (exact): static-band detection and row-hash match ratio for every
/// candidate offset. Stage 2 (tolerant, only when stage 1 finds nothing): the
/// same on 32-cell luminance row descriptors with a mean-difference score.
enum StitchMatcher {
    struct Parameters: Sendable {
        var minimumOverlapFraction: Double
        var matchThreshold: Double
        var noiseTolerance: Float
        var hint: Int?
    }

    static let minimumInformativeRows = 6
    static let minimumOverlapRows = 8

    static func match(previous prev: LineSignatures, current cur: LineSignatures, parameters: Parameters) -> StitchMatchOutcome {
        let h = cur.count
        guard prev.count == h, h > 0 else { return .noMatch }

        // Stage 1: exact row hashes.
        let exactBands = staticBands(height: h) { prev.hashes[$0] == cur.hashes[$0] }
        if exactBands.top >= h { return .duplicate }
        if let found = hashSearch(prev: prev, cur: cur, top: exactBands.top, bottom: h - exactBands.bottom, parameters: parameters) {
            return .match(found)
        }

        // Stage 2: tolerant descriptors.
        let tolerance = parameters.noiseTolerance
        let looseBands = staticBands(height: h) {
            rowDistance(prev.descriptors, $0, cur.descriptors, $0) <= tolerance * 0.5
        }
        if looseBands.top >= h { return .duplicate }
        return descriptorSearch(prev: prev, cur: cur, top: looseBands.top, bottom: h - looseBands.bottom, parameters: parameters)
    }

    /// Leading and trailing rows that are equal at the same position.
    static func staticBands(height h: Int, equal: (Int) -> Bool) -> (top: Int, bottom: Int) {
        var top = 0
        while top < h, equal(top) { top += 1 }
        if top == h { return (h, 0) }
        var bottom = 0
        while bottom < h - top, equal(h - 1 - bottom) { bottom += 1 }
        return (top, bottom)
    }

    private static func searchRange(top a: Int, bottom b: Int, fraction: Double) -> Int? {
        let band = b - a
        let minOverlap = max(minimumOverlapRows, Int((Double(band) * fraction).rounded(.up)))
        let maxOffset = band - minOverlap
        return maxOffset >= 1 ? maxOffset : nil
    }

    private struct Candidate {
        var offset: Int
        var score: Double    // higher is better
        var support: Int
    }

    // MARK: Stage 1

    private static func hashSearch(prev: LineSignatures, cur: LineSignatures, top a: Int, bottom b: Int, parameters: Parameters) -> StitchMatch? {
        guard let maxOffset = searchRange(top: a, bottom: b, fraction: parameters.minimumOverlapFraction) else { return nil }
        var candidates: [Candidate] = []

        prev.hashes.withUnsafeBufferPointer { ph in
            cur.hashes.withUnsafeBufferPointer { ch in
                prev.common.withUnsafeBufferPointer { pc in
                    cur.common.withUnsafeBufferPointer { cc in
                        for d in -maxOffset...maxOffset where d != 0 {
                            let lo = max(a, a - d)
                            let hi = min(b, b - d)
                            var informative = 0
                            var matched = 0
                            for y in lo..<hi {
                                if cc[y] && pc[y + d] { continue }
                                informative += 1
                                if ph[y + d] == ch[y] { matched += 1 }
                            }
                            guard informative >= minimumInformativeRows else { continue }
                            let ratio = Double(matched) / Double(informative)
                            if ratio >= parameters.matchThreshold {
                                candidates.append(Candidate(offset: d, score: ratio, support: matched))
                            }
                        }
                    }
                }
            }
        }
        guard let best = candidates.map(\.score).max() else { return nil }
        let pool = candidates.filter { $0.score >= best - 0.02 }
        guard let chosen = choose(from: pool, hint: parameters.hint) else { return nil }
        return StitchMatch(
            offset: chosen.candidate.offset,
            confidence: 0.9 + 0.1 * min(1, max(0, (chosen.candidate.score - parameters.matchThreshold) / max(0.0001, 1 - parameters.matchThreshold))),
            ambiguous: chosen.ambiguous,
            leadingStatic: a,
            trailingStatic: prev.count - b
        )
    }

    /// Picks among equally good candidates: closest to the hint, otherwise
    /// forward first and then the largest overlap (most matched rows).
    private static func choose(from pool: [Candidate], hint: Int?) -> (candidate: Candidate, ambiguous: Bool)? {
        guard let maxSupport = pool.map(\.support).max() else { return nil }
        let plausible = pool.filter { Double($0.support) >= 0.25 * Double(maxSupport) }
        let ambiguous = plausible.count > 1
        if let hint {
            let pick = plausible.min { l, r in
                let dl = abs(l.offset - hint), dr = abs(r.offset - hint)
                return dl != dr ? dl < dr : l.support > r.support
            }
            return pick.map { ($0, ambiguous) }
        }
        let forward = plausible.filter { $0.offset > 0 }
        let set = forward.isEmpty ? plausible : forward
        let pick = set.max { l, r in
            if l.support != r.support { return l.support < r.support }
            if l.score != r.score { return l.score < r.score }
            return abs(l.offset) > abs(r.offset)
        }
        return pick.map { ($0, ambiguous) }
    }

    // MARK: Stage 2

    static func rowDistance(_ a: [Float], _ ya: Int, _ b: [Float], _ yb: Int) -> Float {
        let n = LineSignatures.binCount
        var sum: Float = 0
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let oa = ya * n, ob = yb * n
                for i in 0..<n { sum += abs(pa[oa + i] - pb[ob + i]) }
            }
        }
        return sum / Float(n)
    }

    private static func descriptorSearch(prev: LineSignatures, cur: LineSignatures, top a: Int, bottom b: Int, parameters: Parameters) -> StitchMatchOutcome {
        guard let maxOffset = searchRange(top: a, bottom: b, fraction: parameters.minimumOverlapFraction) else { return .noMatch }
        let n = LineSignatures.binCount
        let count = 2 * maxOffset + 1
        var scores = [Float](repeating: .infinity, count: count)

        prev.descriptors.withUnsafeBufferPointer { pd in
            cur.descriptors.withUnsafeBufferPointer { cd in
                for d in -maxOffset...maxOffset {
                    let lo = max(a, a - d)
                    let hi = min(b, b - d)
                    let overlap = hi - lo
                    guard overlap >= minimumOverlapRows else { continue }
                    let step = max(1, overlap / 96)
                    var total: Float = 0
                    var rows = 0
                    var y = lo
                    while y < hi {
                        let op = (y + d) * n, oc = y * n
                        var s: Float = 0
                        for i in 0..<n { s += abs(pd[op + i] - cd[oc + i]) }
                        total += s
                        rows += 1
                        y += step
                    }
                    scores[d + maxOffset] = total / Float(rows * n)
                }
            }
        }

        let finite = scores.filter { $0.isFinite }.sorted()
        guard let best = finite.first else { return .noMatch }
        let median = finite[finite.count / 2]
        let tolerance = parameters.noiseTolerance
        // Must be within tolerance and clearly better than a typical offset.
        guard best <= tolerance, best * 2.5 <= median else { return .noMatch }

        let limit = best * 1.3 + 0.3
        var candidates: [Candidate] = []
        for i in 0..<count where scores[i] <= limit {
            let left = i > 0 ? scores[i - 1] : .infinity
            let right = i + 1 < count ? scores[i + 1] : .infinity
            guard scores[i] <= left, scores[i] <= right else { continue }
            let d = i - maxOffset
            let overlap = min(b, b - d) - max(a, a - d)
            // Higher score = better; use the negative distance.
            candidates.append(Candidate(offset: d, score: Double(-scores[i]), support: overlap))
        }
        guard let chosen = chooseTolerant(from: candidates, hint: parameters.hint) else { return .noMatch }
        if chosen.candidate.offset == 0 { return .duplicate }
        let distance = Float(-chosen.candidate.score)
        return .match(StitchMatch(
            offset: chosen.candidate.offset,
            confidence: 0.89 * Double(max(0, 1 - distance / tolerance)),
            ambiguous: chosen.ambiguous,
            leadingStatic: a,
            trailingStatic: prev.count - b
        ))
    }

    private static func chooseTolerant(from pool: [Candidate], hint: Int?) -> (candidate: Candidate, ambiguous: Bool)? {
        let ambiguous = pool.count > 1
        if let hint {
            let pick = pool.min { l, r in
                let dl = abs(l.offset - hint), dr = abs(r.offset - hint)
                return dl != dr ? dl < dr : l.score > r.score
            }
            return pick.map { ($0, ambiguous) }
        }
        let pick = pool.max { l, r in
            if l.score != r.score { return l.score < r.score }
            if (l.offset > 0) != (r.offset > 0) { return r.offset > 0 }
            return l.support < r.support
        }
        return pick.map { ($0, ambiguous) }
    }
}
