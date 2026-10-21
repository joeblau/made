import Foundation

/// Best-alignment fuzzy scoring for the editor's file finder.
///
/// A match is a case-insensitive subsequence, but unlike a greedy matcher this
/// scorer considers every viable alignment and keeps the best one. That matters
/// for paths such as `archive/a---FileFinder.swift`: typing `ff` should select the
/// tight run in `FileFinder`, not commit to an earlier, scattered `f...f` pair.
///
/// The dynamic program is O(query × candidate), with a linear subsequence
/// preflight that rejects the common no-match case before allocating score rows.
/// `PreparedQuery` lets FileFinder parse the query once rather than rebuilding
/// its scalar array for every indexed path.
enum FuzzyMatcher {
    struct PreparedQuery: Sendable {
        fileprivate let scalars: [UnicodeScalar]

        init(_ query: String) {
            scalars = query.unicodeScalars.map(FuzzyMatcher.lowercased)
        }

        var isEmpty: Bool { scalars.isEmpty }
    }

    // Consecutive characters must beat several individually-good boundary
    // hits; otherwise `a_x_b_c` can incorrectly outrank the compact `abc`.
    private static let consecutiveBonus = 32
    private static let boundaryBonus = 30
    private static let startBonus = 35
    private static let basenameBonus = 20
    private static let leadingPenalty = -3
    private static let gapPenalty = -2
    private static let impossible = Int.min / 4

    /// Convenience entry point used by focused tests and one-off callers.
    static func score(query: String, candidate: String) -> Int? {
        score(query: PreparedQuery(query), candidate: candidate)
    }

    /// Returns the score of the best subsequence alignment, or `nil` when the
    /// prepared query cannot be found in `candidate`.
    static func score(query: PreparedQuery, candidate: String) -> Int? {
        if query.isEmpty { return 0 }

        // One-letter searches are extremely broad, so avoid allocating two DP
        // rows for every matching file. The best position is independent here.
        if query.scalars.count == 1 {
            return singleScalarScore(query.scalars[0], in: candidate.unicodeScalars)
        }

        // Reject non-matches in one streaming pass over the scalar view, before
        // materializing a scalar array. Most files disappear here, keeping the
        // more precise dynamic program (and its allocations) cheap even in very
        // large repositories. A successful preflight also guarantees the
        // candidate has at least as many scalars as the query.
        guard containsSubsequence(query.scalars, in: candidate.unicodeScalars) else { return nil }

        let candidateScalars = Array(candidate.unicodeScalars)
        let basenameStart = lastSeparatorIndex(in: candidateScalars).map { $0 + 1 } ?? 0

        var previous = [Int](repeating: impossible, count: candidateScalars.count)

        for queryIndex in query.scalars.indices {
            var current = [Int](repeating: impossible, count: candidateScalars.count)

            // For a gapped transition from candidate index j to i:
            //   previous[j] + gapPenalty * (i - j - 1)
            // = previous[j] - gapPenalty*j + gapPenalty*(i - 1)
            // Keeping the best prefix value makes each DP row linear rather
            // than comparing every pair of candidate positions.
            var bestGappedPrefix = impossible

            for candidateIndex in candidateScalars.indices {
                if queryIndex > 0, candidateIndex >= 2 {
                    let priorIndex = candidateIndex - 2
                    if previous[priorIndex] != impossible {
                        bestGappedPrefix = max(
                            bestGappedPrefix,
                            previous[priorIndex] - gapPenalty * priorIndex
                        )
                    }
                }

                guard lowercased(candidateScalars[candidateIndex]) == query.scalars[queryIndex] else {
                    continue
                }

                let positionalScore = positionBonus(
                    scalars: candidateScalars,
                    index: candidateIndex,
                    basenameStart: basenameStart
                )

                if queryIndex == 0 {
                    current[candidateIndex] = positionalScore + leadingPenalty * candidateIndex
                    continue
                }

                var transitionScore = impossible
                if candidateIndex > 0, previous[candidateIndex - 1] != impossible {
                    transitionScore = previous[candidateIndex - 1] + consecutiveBonus
                }
                if bestGappedPrefix != impossible {
                    transitionScore = max(
                        transitionScore,
                        bestGappedPrefix + gapPenalty * (candidateIndex - 1)
                    )
                }
                if transitionScore != impossible {
                    current[candidateIndex] = transitionScore + positionalScore
                }
            }

            previous = current
        }

        let best = previous.max() ?? impossible
        return best == impossible ? nil : best
    }

    // MARK: - Helpers

    private static func containsSubsequence(
        _ query: [UnicodeScalar],
        in candidate: some Sequence<UnicodeScalar>
    ) -> Bool {
        var queryIndex = 0
        for scalar in candidate where lowercased(scalar) == query[queryIndex] {
            queryIndex += 1
            if queryIndex == query.count { return true }
        }
        return false
    }

    /// Streaming equivalent of the one-letter fast path: two passes over the
    /// scalar view (basename start, then best position) so the broadest queries
    /// never materialize a scalar array per candidate.
    private static func singleScalarScore(
        _ queryScalar: UnicodeScalar,
        in scalars: String.UnicodeScalarView
    ) -> Int? {
        var basenameStart = 0
        var index = 0
        for scalar in scalars {
            index += 1
            if scalar == "/" { basenameStart = index }
        }

        var best = impossible
        var previousScalar: UnicodeScalar?
        index = 0
        for scalar in scalars {
            if lowercased(scalar) == queryScalar {
                var score = 0
                if index == basenameStart {
                    score += startBonus
                } else if isBoundary(previous: previousScalar, current: scalar) {
                    score += boundaryBonus
                }
                if index >= basenameStart {
                    score += basenameBonus
                }
                best = max(best, score + leadingPenalty * index)
            }
            previousScalar = scalar
            index += 1
        }
        return best == impossible ? nil : best
    }

    private static func positionBonus(
        scalars: [UnicodeScalar],
        index: Int,
        basenameStart: Int
    ) -> Int {
        var score = 0
        if index == basenameStart {
            score += startBonus
        } else if index == 0 || isBoundary(scalars, at: index) {
            score += boundaryBonus
        }
        if index >= basenameStart {
            score += basenameBonus
        }
        return score
    }

    private static func lastSeparatorIndex(in scalars: [UnicodeScalar]) -> Int? {
        var index = scalars.count - 1
        while index >= 0 {
            if scalars[index] == "/" { return index }
            index -= 1
        }
        return nil
    }

    /// Separators and camelCase edges are natural filename anchors.
    private static func isBoundary(_ scalars: [UnicodeScalar], at index: Int) -> Bool {
        isBoundary(previous: index > 0 ? scalars[index - 1] : nil, current: scalars[index])
    }

    private static func isBoundary(previous: UnicodeScalar?, current: UnicodeScalar) -> Bool {
        guard let previous else { return true }
        switch previous {
        case "/", "_", "-", ".", " ":
            return true
        default:
            return !isUppercase(previous) && isUppercase(current)
        }
    }

    /// ASCII-fast case folding keeps the per-file hot path allocation-free.
    /// Non-ASCII scalars still match exactly.
    private static func lowercased(_ scalar: UnicodeScalar) -> UnicodeScalar {
        let value = scalar.value
        if value >= 65 && value <= 90 {
            return UnicodeScalar(value + 32)!
        }
        return scalar
    }

    private static func isUppercase(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return value >= 65 && value <= 90
    }
}
