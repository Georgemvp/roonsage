import Foundation

// MARK: - Taste-representative seed selection (Feature 2)
//
// The outward discovery producers (Last.fm similar, ListenBrainz radio, the new
// Qobuz-catalog producer) all expand OUTWARD from a set of seed artists. By
// default those seeds are simply the most-PLAYED artists. This ranks the library's
// artists instead by how central they are to your CLAP taste centroid — the
// artists that best represent *what you actually love* — so every producer
// traverses out from your sonic core, not just your play-count leaders.
//
// CLAP can only rank audio you OWN (unowned Qobuz catalogue isn't embedded), so the
// taste vector's role here is seed SELECTION: pick the most taste-representative
// library artists, then the producers do the artist→artist reach.
public enum TasteSeeds {

    /// Rank library artists by taste representativeness: the cosine of the artist's
    /// mean CLAP embedding to the taste vector (mapped to 0…1), gently boosted by
    /// play count. Returns display-cased artist names, most-representative first,
    /// capped to `limit`. Artists without any embedded track are dropped (no CLAP
    /// signal to rank them on).
    public static func rankArtists(
        library: [DatabaseManager.SonicTrack],
        tasteVector: [Float],
        playCountByArtist: [String: Int],
        limit: Int
    ) -> [String] {
        scoredArtists(library: library, tasteVector: tasteVector, playCountByArtist: playCountByArtist)
            .prefix(max(1, limit)).map(\.display)
    }

    /// Seed selection that deliberately mixes taste-**core** artists with a rotating
    /// sample from the taste **periphery** (artists you own and that are embedded, but
    /// that sit further from your centroid). The outward producers all expand from the
    /// seeds, so seeding only the core makes every discovery feature converge on the
    /// same neighbourhood — the exact overlap this addresses. The periphery sample
    /// steers a slice of the producers toward genuinely different regions, while the
    /// core keeps the bulk on-taste. `salt` (e.g. the day/week) rotates *which*
    /// periphery artists come in run-to-run; empty salt → deterministic (tests).
    /// Falls back to the plain core ranking when there's too little to diversify.
    public static func diversifiedSeeds(
        library: [DatabaseManager.SonicTrack],
        tasteVector: [Float],
        playCountByArtist: [String: Int],
        limit: Int,
        exploreCount: Int,
        salt: String
    ) -> [String] {
        let limit = max(1, limit)
        let scored = scoredArtists(library: library, tasteVector: tasteVector, playCountByArtist: playCountByArtist)
        let explore = max(0, min(exploreCount, limit - 1))
        let coreN = limit - explore
        // Too small a pool to have a meaningful periphery → just the core ranking.
        guard explore > 0, scored.count > coreN else { return scored.prefix(limit).map(\.display) }

        let core = Array(scored.prefix(coreN))
        // Near-periphery window: the artists right beyond the core (still recognisably
        // yours, not the noisy anti-taste tail), capped so the sample stays relevant.
        let window = Array(scored.dropFirst(coreN).prefix(max(explore * 6, 40)))
        // Weighted sampling without replacement (Efraimidis-Spirakis: key = u^(1/w)),
        // weight = the artist's own score so the more-you end of the periphery is
        // likelier; `u` deterministic per salt per artist so it rotates but reproduces.
        let keyed = window.map { item -> (display: String, key: Double) in
            let u = salt.isEmpty ? 0.5
                : (Double(RoonClient.seed64("\(salt)\u{1f}\(item.display.lowercased())") % 1_000_000) + 0.5) / 1_000_000
            return (item.display, pow(u, 1.0 / max(item.score, 1e-6)))
        }
        let sampled = keyed.sorted { $0.key > $1.key }.prefix(explore).map(\.display)
        // Core first (stable), then the rotating periphery; de-dup defensively.
        var seen = Set<String>()
        return (core.map(\.display) + sampled).filter { seen.insert($0.lowercased()).inserted }
    }

    // MARK: scoring

    /// Every embedded library artist scored by cosine(taste, artist-centroid) mapped
    /// to 0…1 and gently play-boosted, best first (name-tiebroken → deterministic).
    private static func scoredArtists(
        library: [DatabaseManager.SonicTrack],
        tasteVector: [Float],
        playCountByArtist: [String: Int]
    ) -> [(display: String, score: Double)] {
        guard !tasteVector.isEmpty else { return [] }
        let taste = normalized(tasteVector)

        struct Acc { var sum: [Float]; var count: Int; var display: String }
        var byArtist: [String: Acc] = [:]
        for t in library {
            guard let a = t.artist, !a.isEmpty, let emb = t.embedding, emb.count == taste.count else { continue }
            let key = a.lowercased()
            if var acc = byArtist[key] {
                for i in 0..<emb.count { acc.sum[i] += emb[i] }
                acc.count += 1
                byArtist[key] = acc
            } else {
                byArtist[key] = Acc(sum: emb, count: 1, display: a)
            }
        }
        guard !byArtist.isEmpty else { return [] }

        var scored: [(display: String, score: Double)] = []
        scored.reserveCapacity(byArtist.count)
        for (key, acc) in byArtist {
            let mean = normalized(acc.sum)                     // artist centroid direction
            let cos = Double(dot(mean, taste))                 // -1…1
            let cosMapped = (cos + 1) / 2                      // 0…1
            let plays = Double(playCountByArtist[key] ?? 0)
            let playBoost = 1 + 0.35 * log(1 + plays)          // heavy rotation nudges up
            scored.append((acc.display, cosMapped * playBoost))
        }
        // Deterministic: sort by score desc, then by name so ties are stable.
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.display.lowercased() < $1.display.lowercased() }
        return scored
    }

    // MARK: helpers

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var s: Float = 0
        let n = min(a.count, b.count)
        var i = 0
        while i < n { s += a[i] * b[i]; i += 1 }
        return s
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }
}
