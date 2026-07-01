import Foundation

// MARK: - Discogs Labels producer (F7)
//
// Finds artists you don't know via the record labels behind artists you DO
// play — a genuinely different discovery angle from the Last.fm/MB-relationship
// producers (a shared LABEL, not shared listeners or a collaboration credit).
// Gated: needs a Discogs personal access token (Settings → Externe diensten).
// Every candidate still passes MusicBrainz validation in the pipeline's Resolve
// stage like any other producer, so a messy Discogs artist-name/compilation
// entry just fails to resolve rather than becoming a wrong recommendation.

public struct DiscogsLabelsProducer: DiscoveryProducer {
    public let id = "discogs-labels"
    /// How many top-played seed artists to spend the label-lookup budget on —
    /// each costs ~2–3 Discogs calls (search + release detail + label releases),
    /// so this stays small and well under Discogs's 60/min authenticated limit.
    private let seedArtistCount = 6
    private let releasesPerLabel = 30

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { context.discogsToken != nil }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let token = context.discogsToken else { return [] }
        let seedArtists = Array(seeds.topArtists.prefix(seedArtistCount))
        guard !seedArtists.isEmpty else { return [] }

        var known = Set(seeds.topArtists.map { $0.lowercased() })
        known.formUnion(seeds.likedArtists.map { $0.lowercased() })
        known.formUnion(seeds.libraryArtists)

        var seenLabels = Set<Int>()
        var out: [Candidate] = []
        for artist in seedArtists {
            guard let label = await DiscogsClient.shared.primaryLabel(forArtist: artist, token: token),
                  seenLabels.insert(label.id).inserted else { continue }
            let releases = await DiscogsClient.shared.releases(forLabel: label, limit: releasesPerLabel, token: token)
            for r in releases {
                let key = r.artist.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !known.contains(key) else { continue }
                known.insert(key)   // one candidate per newly-seen artist, even if they're on several seed labels
                out.append(Candidate(
                    kind: .album, artist: r.artist, album: r.title, year: r.year,
                    sourceURL: "https://www.discogs.com/label/\(label.id)", producer: id))
                if out.count >= context.perProducerLimit { return out }
            }
        }
        return out
    }
}
