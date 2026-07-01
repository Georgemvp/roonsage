import Foundation

// MARK: - Gap-Fill producer
//
// Studio albums you're missing from artists you already play (top-played, as a
// proxy for "artists you track" — RoonSage has no separate follow-list concept
// beyond the discovery watchlist). Diffs MusicBrainz's studio discography against
// the owned-album set; every miss gets `gapPriority = 1.0` (a full album modifier
// nudge — see DiscoveryScoring.applyAlbumModifier).

public struct GapFillProducer: DiscoveryProducer {
    public let id = "gap-fill"

    /// Cap on artists checked per run — each needs an MB resolve + a discography
    /// fetch, both rate-limited (digarr's DEFAULT_MAX_ARTISTS_PER_RUN = 25).
    private let maxArtists = 20
    private let maxPerArtist = 3

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { true }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard !seeds.topArtists.isEmpty else { return [] }
        var out: [Candidate] = []
        for artist in seeds.topArtists.prefix(maxArtists) {
            guard let match = await context.musicBrainz.resolveArtist(name: artist) else { continue }
            let albums = await context.musicBrainz.studioAlbums(artistMbid: match.mbid)
            guard !albums.isEmpty else { continue }
            let missing = albums.filter { rg in
                !seeds.libraryAlbumKeys.contains(Self.albumKey(artist: match.name, album: rg.title))
            }
            for rg in missing.prefix(maxPerArtist) {
                out.append(Candidate(kind: .album, artist: match.name, album: rg.title, year: rg.year,
                                     similarity: 0.6, producer: id, artistMbid: match.mbid,
                                     releaseGroupMbid: rg.mbid, gapPriority: 1.0))
            }
        }
        return Array(out.prefix(context.perProducerLimit))
    }

    private static func albumKey(artist: String, album: String) -> String {
        "\(artist.lowercased().trimmingCharacters(in: .whitespaces))|\(album.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}
