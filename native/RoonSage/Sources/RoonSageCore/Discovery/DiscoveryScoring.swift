import Foundation

// MARK: - Discovery scoring (pure — unit-tested in DiscoveryScoringTests)
//
// The weighted-composite score, adapted from digarr's score.ts:
//   score = 0.30·consensus + 0.25·similarity + 0.20·genreOverlap
//         + 0.15·aiConfidence + 0.10·feedbackBoost + 0.00·popularity
// then bounded post-modifiers nudge the ranking without touching the sum-to-1
// weights (so the "veilig ↔ avontuurlijk" dial stays valid):
//   • album modifier (±0.15) from recency (smooth logistic decay) + gap-priority
//   • producer-reliability nudge (±0.08, C3) from your accept-rate per producer
//   • dial-aware popularity nudge (±0.10, C2) — "veilig" favours known artists,
//     "avontuurlijk" favours obscure ones
// Every function is pure and takes primitives so it tests without a DB or network.

public enum DiscoveryScoring {

    /// How hard a fully strong-negative genre is downweighted (digarr's
    /// STRONG_NEGATIVE_PENALTY). Scales with the strong-negative rejection fraction.
    static let strongNegativePenalty = 0.5

    /// Months at which the recency signal crosses 0.5 — the logistic midpoint.
    static let recencyMidpointMonths = 18.0
    /// Logistic steepness: higher = a sharper transition around the midpoint.
    static let recencySteepness = 0.25

    /// Max nudge the album modifier can add/subtract on top of the artist base.
    static let albumModifierWeight = 0.15

    /// Max nudge from a candidate's producers' historical accept-rate (C3). Small
    /// so it only breaks ties between otherwise similar scores — a producer that
    /// consistently earns your "Bewaar" nudges its picks up; one you keep skipping
    /// nudges them down. Bounded, like the album modifier.
    static let producerReliabilityWeight = 0.08

    /// Max nudge from artist popularity (C2), applied dial-aware: "veilig" leans
    /// toward well-known artists, "avontuurlijk" toward obscure ones.
    static let popularityModifierWeight = 0.10

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

    /// Map a release date/year to a recency signal in [0, 1] via a smooth logistic
    /// decay: a plateau near 1 for fresh releases, a soft S-curve through 0.5 at
    /// `recencyMidpointMonths`, and a long tail toward 0 for old ones — no hard
    /// cliff at a fixed cutoff (the previous linear decay zeroed abruptly at 24
    /// months, so an album 23.9 vs 24.1 months old scored discontinuously). Future
    /// clamps to 1; unparseable → 0.5 (no signal). Accepts "YYYY-MM-DD", "YYYY-MM",
    /// or a bare "YYYY".
    public static func recency(releaseDate: String?, now: Date) -> Double {
        guard let released = parseReleaseDate(releaseDate) else { return 0.5 }
        let monthsSince = now.timeIntervalSince(released) / (60 * 60 * 24 * 30.44)
        if monthsSince <= 0 { return 1 }
        return 1 / (1 + exp(recencySteepness * (monthsSince - recencyMidpointMonths)))
    }

    /// A bounded nudge from how often the producers that surfaced this item have
    /// historically been ACCEPTED (C3 — a light per-user learning loop over the
    /// existing "Ontdek-inzichten" accept-rates). `reliabilities[producer]` = its
    /// accept-rate 0…1; producers with no decision history are ignored. All-unknown
    /// → 0 (no change). Centered at 0.5: a producer accepted >50% lifts, <50% trims,
    /// within ±`producerReliabilityWeight`.
    public static func producerReliabilityNudge(producers: [String],
                                                reliabilities: [String: Double]) -> Double {
        let known = producers.compactMap { reliabilities[$0] }
        guard !known.isEmpty else { return 0 }
        let mean = known.reduce(0, +) / Double(known.count)
        return producerReliabilityWeight * (mean - 0.5) * 2
    }

    /// Normalise a Last.fm listener count to a 0…1 popularity signal on a log scale
    /// (listeners are heavily power-law distributed). ~100 listeners → ~0, ~1M → ~1.
    /// nil count → nil (no signal, so the modifier leaves the score untouched).
    public static func popularity(listeners: Int?) -> Double? {
        guard let listeners, listeners > 0 else { return listeners == 0 ? 0 : nil }
        // log10(1) = 0 … log10(1_000_000) = 6 → divide by 6, clamp to [0,1].
        return min(max(log10(Double(listeners)) / 6.0, 0), 1)
    }

    /// A bounded, dial-aware nudge from artist popularity (C2). `adventurousness`
    /// flips the direction: at 0 ("veilig") a popular artist lifts the score and an
    /// obscure one trims it; at 1 ("avontuurlijk") the preference inverts, favouring
    /// deep cuts. nil popularity → 0. Bounded by `popularityModifierWeight`.
    public static func popularityNudge(popularity: Double?, adventurousness: Double) -> Double {
        guard let pop = popularity else { return 0 }
        let t = min(max(adventurousness, 0), 1)
        let direction = 1 - 2 * t                    // +1 at safe → −1 at bold
        return popularityModifierWeight * (pop - 0.5) * 2 * direction
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
