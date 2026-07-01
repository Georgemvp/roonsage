import Foundation

// MARK: - Charts producer
//
// Trending artists via Last.fm's global chart (`chart.gettopartists`). No taste
// seed — pure zeitgeist, meant to nudge the feed toward what's currently popular.
// A rank-based decay stands in for similarity since Last.fm gives no numeric
// score here; genreOverlap/consensus do the real taste-fitting downstream.

public struct ChartsProducer: DiscoveryProducer {
    public let id = "charts"
    private let limit = 40

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { context.lastfm != nil }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let creds = context.lastfm else { return [] }
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })
        let artists = await LastfmClient.shared.getTopArtistsByCountry(
            country: "global", apiKey: creds.apiKey, limit: limit)

        var out: [Candidate] = []
        for (i, a) in artists.enumerated() {
            let key = a.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !seeds.libraryArtists.contains(key), !disliked.contains(key) else { continue }
            let decay = max(0.3, 1 - Double(i) * 0.02)
            out.append(Candidate(kind: .artist, artist: a.name, similarity: decay, producer: id, artistMbid: a.mbid))
        }
        return Array(out.prefix(context.perProducerLimit))
    }
}
