import Foundation

// MARK: - Discovery re-rank (pure — unit-tested in DiscoveryRerankTests)
//
// The Score stage ranks every candidate by relevance; taking a plain top-N off
// that list lets one artist's albums or one genre neighbourhood dominate a batch
// (the recurring "every Ontdek surface shows near-identical picks" complaint).
// MMR (Maximal Marginal Relevance, Carbonell & Goldstein 1998) fixes that: it
// greedily picks the item maximizing
//     λ·relevance − (1−λ)·maxSimilarityToAlreadyPicked,
// so a near-duplicate of something already chosen is deferred in favour of an
// equally-on-taste but more distinct alternative. Relevance stays dominant (λ
// high) — this only breaks up clusters, it never overrides the score's ranking.

public enum DiscoveryRerank {

    /// λ — how strongly relevance dominates diversity. 0.75 keeps the score the
    /// primary driver (a clearly better pick always wins) while still deferring
    /// near-duplicates when scores are close.
    public static let diversityWeight = 0.75

    /// Candidate-to-candidate redundancy for MMR: two items by the SAME artist are
    /// maximally similar (stops one artist's albums clustering), otherwise the
    /// Jaccard overlap of their genre sets. No genres on either side → 0 (treated
    /// as distinct — MMR must not punish items we simply have no genre data for).
    public static func similarity(artistA: String, genresA: Set<String>,
                                  artistB: String, genresB: Set<String>) -> Double {
        if !artistA.isEmpty, artistA == artistB { return 1 }
        guard !genresA.isEmpty, !genresB.isEmpty else { return 0 }
        let union = genresA.union(genresB).count
        return union == 0 ? 0 : Double(genresA.intersection(genresB).count) / Double(union)
    }

    /// Maximal Marginal Relevance selection. `items` MUST be pre-sorted by
    /// relevance descending (the caller's Score-stage order). Returns up to `limit`
    /// items in pick order — relevance-led, with near-duplicates interleaved later.
    /// Fewer items than `limit` (or ≤1 item) is a no-op reorder that just returns
    /// them unchanged.
    public static func mmr<T>(_ items: [T], limit: Int,
                              relevance: (T) -> Double,
                              artist: (T) -> String,
                              genres: (T) -> [String],
                              lambda: Double = diversityWeight) -> [T] {
        guard limit > 0 else { return [] }
        guard items.count > 1 else { return Array(items.prefix(limit)) }
        let arts = items.map { artist($0).lowercased().trimmingCharacters(in: .whitespaces) }
        let gens = items.map { Set(genres($0).map { $0.lowercased() }) }
        let rels = items.map(relevance)

        var remaining = Array(items.indices)   // preserves relevance-desc order
        var picked: [Int] = []
        let cap = min(limit, items.count)
        while picked.count < cap, !remaining.isEmpty {
            var bestPos = 0
            var bestVal = -Double.infinity
            for (pos, idx) in remaining.enumerated() {
                let mmrVal: Double
                if picked.isEmpty {
                    mmrVal = rels[idx]                       // first pick = highest relevance
                } else {
                    var maxSim = 0.0
                    for p in picked {
                        let s = similarity(artistA: arts[idx], genresA: gens[idx],
                                           artistB: arts[p], genresB: gens[p])
                        if s > maxSim { maxSim = s }
                    }
                    mmrVal = lambda * rels[idx] - (1 - lambda) * maxSim
                }
                // Strict `>` keeps the earliest (= higher-relevance) item on ties.
                if mmrVal > bestVal { bestVal = mmrVal; bestPos = pos }
            }
            picked.append(remaining.remove(at: bestPos))
        }
        return picked.map { items[$0] }
    }
}
