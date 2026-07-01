import Foundation

// MARK: - Qobuz-catalogue producer (Feature 2)
//
// Discovers not-yet-owned albums straight from the Qobuz catalogue for your most
// taste-representative artists (the seeds are taste-ranked upstream — see
// TasteSeeds). Where GapFillProducer diffs MusicBrainz's studio discography, this
// hits Qobuz directly: every candidate is already known to exist on Qobuz and is
// immediately playable/saveable once the pipeline resolves it, with no MusicBrainz
// round-trip. Album-kind, so it flows through the same resolve/score/filter path.

public struct QobuzCatalogProducer: DiscoveryProducer {
    public let id = "qobuz-catalog"

    /// Cap on seed artists per run — each is one Qobuz search, so this bounds
    /// latency (matches SimilarArtistWebProducer's budget).
    private let maxSeeds = 12
    private let maxPerArtist = 4

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { context.qobuz != nil }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let q = context.qobuz else { return [] }
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })

        // Liked first (strongest signal), then the taste-ranked top artists. Deduped,
        // capped, disliked seeds skipped.
        var seedList: [String] = []
        var seen = Set<String>()
        for a in seeds.likedArtists + seeds.topArtists {
            let k = a.lowercased()
            guard !k.isEmpty, !disliked.contains(k), seen.insert(k).inserted else { continue }
            seedList.append(a)
            if seedList.count >= maxSeeds { break }
        }
        guard !seedList.isEmpty else { return [] }

        var out: [Candidate] = []
        var seenAlbum = Set<String>()
        for artist in seedList {
            let albums = await QobuzClient.shared.searchArtistAlbums(
                artist: artist, email: q.email, password: q.password, limit: maxPerArtist * 2)
            var added = 0
            for alb in albums {
                let key = Self.albumKey(artist: alb.artist, album: alb.title)
                if seeds.libraryAlbumKeys.contains(key) { continue }       // already owned
                if disliked.contains(alb.artist.lowercased()) { continue }
                guard seenAlbum.insert(key).inserted else { continue }
                let year = alb.releaseDate.flatMap { Int($0.prefix(4)) }
                out.append(Candidate(kind: .album, artist: alb.artist, album: alb.title, year: year,
                                     similarity: 0.6, producer: id, gapPriority: 0.8))
                added += 1
                if added >= maxPerArtist { break }
            }
        }
        return Array(out.prefix(context.perProducerLimit))
    }

    private static func albumKey(artist: String, album: String) -> String {
        "\(artist.lowercased().trimmingCharacters(in: .whitespaces))|\(album.lowercased().trimmingCharacters(in: .whitespaces))"
    }
}
