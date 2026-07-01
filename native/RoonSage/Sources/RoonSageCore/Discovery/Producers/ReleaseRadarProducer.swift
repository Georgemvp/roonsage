import Foundation

// MARK: - Release-Radar producer
//
// New studio albums from artists on the watchlist (fed by Accept — see
// RoonClient+Discovery). Emits only releases newer than the artist's
// `lastSeenReleaseGroup` watermark, so a followed artist's back-catalogue isn't
// dumped as "new" — that's Gap-Fill's job. The watermark itself is advanced by
// the caller after each run (RoonClient+Discovery.runDiscoveryPipeline), not by
// this producer, keeping producers read-only/stateless.

public struct ReleaseRadarProducer: DiscoveryProducer {
    public let id = "release-radar"

    /// Cap on watchlist artists checked per run — each needs an MB resolve (if no
    /// MBID yet) + a release-group fetch, both rate-limited.
    private let maxArtists = 30
    /// Cap on "new" releases surfaced per artist in one run.
    private let maxPerArtist = 3

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { true }   // needs only the watchlist + MB

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard !seeds.watchlist.isEmpty else { return [] }
        var out: [Candidate] = []
        for artist in seeds.watchlist.prefix(maxArtists) {
            guard let mbid = await resolvedMbid(for: artist, context: context) else { continue }
            let albums = await context.musicBrainz.studioAlbums(artistMbid: mbid)
            guard !albums.isEmpty else { continue }
            let fresh = Self.newReleasesSinceSeen(sortedByDateDesc: albums, lastSeen: artist.lastSeenReleaseGroup)
            for rg in fresh.prefix(maxPerArtist) {
                out.append(Candidate(kind: .album, artist: artist.displayName, album: rg.title, year: rg.year,
                                     similarity: 0.8, producer: id, artistMbid: mbid, releaseGroupMbid: rg.mbid))
            }
        }
        return Array(out.prefix(context.perProducerLimit))
    }

    private func resolvedMbid(for artist: WatchlistArtist, context: ProducerContext) async -> String? {
        if let mbid = artist.artistMbid, !mbid.isEmpty { return mbid }
        return await context.musicBrainz.resolveArtist(name: artist.displayName)?.mbid
    }

    /// Pure: releases strictly newer (by position in the newest-first list) than
    /// `lastSeen`. `lastSeen == nil` (never scanned) returns only the single
    /// newest release — a fresh watchlist add doesn't dump its whole discography
    /// as "new". `lastSeen` not found in the list (edge case: MB data changed)
    /// falls back to the newest release only, same as the never-scanned case.
    static func newReleasesSinceSeen(
        sortedByDateDesc albums: [MusicBrainzDiscoveryClient.MBReleaseGroup], lastSeen: String?
    ) -> [MusicBrainzDiscoveryClient.MBReleaseGroup] {
        guard !albums.isEmpty else { return [] }
        guard let lastSeen, !lastSeen.isEmpty else { return Array(albums.prefix(1)) }
        guard let idx = albums.firstIndex(where: { $0.mbid == lastSeen }) else { return Array(albums.prefix(1)) }
        return Array(albums.prefix(idx))   // everything strictly before (newer than) lastSeen
    }
}
