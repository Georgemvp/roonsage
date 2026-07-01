import Foundation

// MARK: - Discovery scoring (pure — unit-tested in DiscoveryScoringTests)
//
// The weighted-composite score, adapted verbatim from digarr's score.ts:
//   score = 0.30·consensus + 0.25·similarity + 0.20·genreOverlap
//         + 0.15·aiConfidence + 0.10·feedbackBoost + 0.00·popularity
// plus a bounded album modifier (±0.15) from recency / popularity / gap-priority.
// Every function is pure and takes primitives so it tests without a DB or network.

public enum DiscoveryScoring {

    /// How hard a fully strong-negative genre is downweighted (digarr's
    /// STRONG_NEGATIVE_PENALTY). Scales with the strong-negative rejection fraction.
    static let strongNegativePenalty = 0.5

    /// Months over which the album recency signal decays linearly from 1 → 0.
    static let recencyDecayMonths = 24.0

    /// Max nudge the album modifier can add/subtract on top of the artist base.
    static let albumModifierWeight = 0.15

    // MARK: Components

    /// How many distinct sources found this candidate, capped (digarr caps at 4).
    public static func consensus(distinctSources: Int) -> Double {
        min(Double(max(0, distinctSources)) / 4.0, 1.0)
    }

    /// Fraction of the candidate's genres that overlap the library's genre set.
    /// Returns 0 when the candidate has no genre data (neutral, not penalising).
    public static func genreOverlap(candidateGenres: [String], libraryGenres: Set<String>) -> Double {
        let cand = candidateGenres.map { $0.lowercased() }
        guard !cand.isEmpty else { return 0 }
        let hits = cand.filter { libraryGenres.contains($0) }.count
        return Double(hits) / Double(cand.count)
    }

    /// Per-genre approve-rate with a strong-negative penalty, averaged across the
    /// candidate's genres. A genre with no feedback history contributes 0.5
    /// (parity with digarr's approve-rate-only default). `rates[genre]` =
    /// (approve: likes/total, strongNeg: strongNegativeRejections/total).
    public static func feedbackBoost(candidateGenres: [String],
                                     rates: [String: (approve: Double, strongNeg: Double)]) -> Double {
        let cand = candidateGenres.map { $0.lowercased() }
        guard !cand.isEmpty else { return 0.5 }
        let perGenre = cand.map { g -> Double in
            guard let r = rates[g] else { return 0.5 }
            let penalty = strongNegativePenalty * r.strongNeg
            return max(0, r.approve * (1 - penalty))
        }
        return perGenre.reduce(0, +) / Double(perGenre.count)
    }

    /// The weighted composite of the six base components (NOT the album modifier —
    /// that is applied afterwards by `applyAlbumModifier`). Clamped to [0, 1].
    public static func weightedScore(_ w: ScoringWeights, _ c: ScoreComponents) -> Double {
        let raw =
            w.consensus    * c.consensus +
            w.similarity   * c.similarity +
            w.genreOverlap * c.genreOverlap +
            w.aiConfidence * c.aiConfidence +
            w.feedbackBoost * c.feedbackBoost +
            w.popularity   * c.popularity
        return min(max(raw, 0), 1)
    }

    // MARK: Album modifier

    /// Map a release date/year to a recency signal in [0, 1]: just-released ≈ 1,
    /// `recencyDecayMonths` or older → 0, future clamps to 1. Unparseable → 0.5
    /// (no signal). Accepts "YYYY-MM-DD", "YYYY-MM", or a bare "YYYY".
    public static func recency(releaseDate: String?, now: Date) -> Double {
        guard let released = parseReleaseDate(releaseDate) else { return 0.5 }
        let monthsSince = now.timeIntervalSince(released) / (60 * 60 * 24 * 30.44)
        if monthsSince <= 0 { return 1 }
        return min(max(1 - monthsSince / recencyDecayMonths, 0), 1)
    }

    /// Album score = artist base + a bounded modifier from the album signals'
    /// mean (each 0…1, mapped to −weight…+weight). Nil signals are ignored; all-nil
    /// leaves the base untouched. Clamped to [0, 1]. (digarr's applyAlbumModifier.)
    public static func applyAlbumModifier(base: Double, recency: Double?, popularity: Double?,
                                          gapPriority: Double?) -> Double {
        let present = [recency, popularity, gapPriority].compactMap { $0 }
        guard !present.isEmpty else { return min(max(base, 0), 1) }
        let avg = present.reduce(0, +) / Double(present.count)
        let nudge = albumModifierWeight * (avg - 0.5) * 2   // 0…1 → −weight…+weight
        return min(max(base + nudge, 0), 1)
    }

    // MARK: Helpers

    static func parseReleaseDate(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        let parts = s.split(separator: "-")
        guard let y = Int(parts.first ?? ""), y > 0 else { return nil }
        comps.year = y
        comps.month = parts.count > 1 ? Int(parts[1]) : 1
        comps.day = parts.count > 2 ? Int(parts[2]) : 1
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: comps)
    }
}
