import Foundation

// MARK: - Text-seeded discovery (CLAP long-tail, fase 2 — "iets als deze vibe")
//
// A free-text vibe ("shimmering ambient techno, no vocals") is CLAP text-embedded
// and kNN'd against the OWNED library in the shared CLAP space; the artists behind
// the nearest owned tracks become the seed every producer expands from — the
// free-text generalisation of F12a's fixed 6 mood buckets. This is the pure
// aggregation half (ranking artists from the nearest-track hits); the CLAP embed
// + VectorIndex kNN live in the pipeline. Mirrors `MoodSeeding.topArtists`'
// mean-score-per-artist ranking, but over generic (artist, cosine) hits.

public enum DiscoveryTextSeeding {

    /// Artists behind the query-nearest owned tracks, ranked by their MEAN cosine
    /// to the query across their hits (needs ≥ `minTracks` hits, so one lucky track
    /// can't crown an artist), highest first, returned in first-seen display case.
    /// Empty when nothing clears the threshold (caller falls back to the unbiased
    /// seed). Pure/testable — the caller feeds it `VectorIndex.nearest(...)` hits.
    public static func topArtists(_ hits: [(artist: String?, score: Float)],
                                  limit: Int, minTracks: Int = 2) -> [String] {
        guard limit > 0 else { return [] }
        var sums: [String: (total: Float, count: Int, display: String)] = [:]
        for h in hits {
            guard let raw = h.artist?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { continue }
            let k = raw.lowercased()
            var entry = sums[k] ?? (0, 0, raw)
            entry.total += h.score; entry.count += 1
            sums[k] = entry
        }
        return sums.values
            .filter { $0.count >= minTracks }
            .sorted { lhs, rhs in
                let l = lhs.total / Float(lhs.count), r = rhs.total / Float(rhs.count)
                return l != r ? l > r : lhs.display < rhs.display   // stable tie-break
            }
            .prefix(limit)
            .map(\.display)
    }
}
