import Foundation

// MARK: - Similar-Artist-Web producer
//
// Seeds on the user's top-played + thumbed-up artists and asks Last.fm for each
// one's similar artists, aggregating them into artist-kind candidates. Cross-seed
// agreement isn't the consensus signal (that's cross-PRODUCER); within this
// producer a neighbour surfaced by several seeds keeps its highest match score.

public struct SimilarArtistWebProducer: DiscoveryProducer {
    public let id = "similar-artist-web"

    /// Cap on seed artists per run — each is one Last.fm call, so this bounds both
    /// latency and the downstream MB-resolve load.
    private let maxSeeds = 12
    private let neighboursPerSeed = 20

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { context.lastfm != nil }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let creds = context.lastfm else { return [] }

        // Liked artists first (strongest taste signal), then top-played. Deduped,
        // capped. Skip disliked seeds outright.
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })
        var seedList: [String] = []
        var seen = Set<String>()
        for a in seeds.likedArtists + seeds.topArtists {
            let k = a.lowercased()
            guard !k.isEmpty, !disliked.contains(k), seen.insert(k).inserted else { continue }
            seedList.append(a)
            if seedList.count >= maxSeeds { break }
        }
        guard !seedList.isEmpty else { return [] }

        // Neighbours we should NOT re-suggest: the seeds themselves and anything
        // already owned (the filter re-checks, but skipping here saves resolve work).
        var byName: [String: Candidate] = [:]
        for seed in seedList {
            let sims = await LastfmClient.shared.getSimilarArtists(
                artist: seed, apiKey: creds.apiKey, limit: neighboursPerSeed)
            for s in sims {
                let key = s.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !seeds.libraryArtists.contains(key), !disliked.contains(key) else { continue }
                let cand = Candidate(kind: .artist, artist: s.name,
                                     similarity: s.match ?? 0.5, producer: id, artistMbid: s.mbid)
                if let existing = byName[key], (existing.similarity ?? 0) >= (cand.similarity ?? 0) { continue }
                byName[key] = cand
            }
        }

        return Array(byName.values
            .sorted { ($0.similarity ?? 0) > ($1.similarity ?? 0) }
            .prefix(context.perProducerLimit))
    }
}
