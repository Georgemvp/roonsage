import Foundation

// MARK: - Deezer Related producer
//
// Deezer's "fans also like" fan graph as an OUTWARD discovery source — a second,
// independent collaborative signal alongside Last.fm's `getSimilar` and LB's
// radio graph (different audience → different neighbours, so it widens reach
// rather than echoing them). Reuses the existing keyless `RelatedArtistsClient`
// (which already name-confirms the seed so a common prefix can't inherit an
// unrelated star's graph) — that client also powers in-library radio sequencing;
// here we keep only the related artists you DON'T already own. Keyless public
// API, so no credentials to gate on; still switch-off-able via the per-producer
// tuning toggle. Every candidate is MB-validated in Resolve like any other.

public struct DeezerRelatedProducer: DiscoveryProducer {
    public let id = "deezer-related"
    /// Seed artists to expand from — each costs two Deezer calls (search + related),
    /// paced by the client; a handful keeps a run well under Deezer's ceiling.
    private let seedArtistCount = 8
    private let relatedPerSeed = 25

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { true }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })

        // Seed liked-first, then top-played — same posture as the LB/Last.fm producers.
        var seedList: [String] = []
        var seen = Set<String>()
        for a in seeds.likedArtists + seeds.topArtists {
            let k = a.lowercased()
            guard !k.isEmpty, !disliked.contains(k), seen.insert(k).inserted else { continue }
            seedList.append(a)
            if seedList.count >= seedArtistCount { break }
        }
        guard !seedList.isEmpty else { return [] }

        var known = seeds.libraryArtists
        known.formUnion(seeds.topArtists.map { $0.lowercased() })
        known.formUnion(seeds.likedArtists.map { $0.lowercased() })

        var out: [Candidate] = []
        var emitted = Set<String>()
        for seed in seedList {
            guard let related = await RelatedArtistsClient.shared.relatedArtists(for: seed, limit: relatedPerSeed),
                  !related.isEmpty else { continue }
            for (i, name) in related.enumerated() {
                let key = name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !known.contains(key), !disliked.contains(key),
                      emitted.insert(key).inserted else { continue }
                // Deezer returns affinity order; decay the leading picks harder-pulling
                // (0.9) down to ~0.4 at the tail.
                let score = max(0.4, 0.9 - Double(i) * 0.02)
                out.append(Candidate(kind: .artist, artist: name, similarity: score, producer: id))
                if out.count >= context.perProducerLimit { return out }
            }
        }
        return out
    }
}
