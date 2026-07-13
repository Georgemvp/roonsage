import Foundation

// MARK: - ListenBrainz-Exploration producer
//
// ListenBrainz's OWN personalized recommendations — the part of LB that goes
// beyond the artist-to-artist similarity graph `ListenBrainzRadioProducer`
// already mines. Two sources, both pre-computed by LB for this exact user:
//
//  • "Weekly Exploration" (a `createdfor` playlist) → NEW-to-you artists LB's
//    recommender surfaced from listeners like you. Emitted as artist candidates
//    (the library filter drops any you already own — that's the whole point).
//  • `fresh_releases` → new/just-out ALBUMS from artists you actually listen to,
//    broader than the watchlist-only Release-Radar. Emitted as album candidates,
//    future-dated and non-Album releases dropped, owned albums pre-filtered.
//
// Deliberately separate from the Radio producer so the insights dashboard tracks
// this source's accept-rate on its own.

public struct ListenBrainzExplorationProducer: DiscoveryProducer {
    public let id = "listenbrainz-exploration"

    /// How many days back `fresh_releases` looks (LB caps this server-side).
    private let freshReleaseDays = 90

    public init() {}

    public func isEnabled(_ context: ProducerContext) -> Bool { context.listenBrainz != nil }

    public func discover(seeds: DiscoverySeeds, context: ProducerContext) async -> [Candidate] {
        guard let creds = context.listenBrainz, let token = creds.token, !token.isEmpty else { return [] }
        let disliked = Set(seeds.dislikedArtists.map { $0.lowercased() })
        var out: [Candidate] = []

        // 1) Weekly Exploration → new-to-you artists.
        out += await explorationArtists(username: creds.username, token: token,
                                        library: seeds.libraryArtists, disliked: disliked)

        // 2) fresh_releases → new albums from artists you listen to.
        out += await freshAlbums(username: creds.username, token: token,
                                 libraryAlbumKeys: seeds.libraryAlbumKeys, disliked: disliked)

        return Array(out.prefix(context.perProducerLimit))
    }

    // MARK: - Sources

    private func explorationArtists(username: String, token: String,
                                    library: Set<String>, disliked: Set<String>) async -> [Candidate] {
        let refs = await ListenBrainzClient.shared.userPlaylists(username: username, token: token, includeCreatedFor: true)
        // Only the genuinely outward playlist(s): "Weekly Exploration" is new music.
        // "Weekly/Daily Jams" are re-listens of music you already own, so skip them
        // (they'd be filtered out downstream anyway, at the cost of a wasted fetch).
        let chosen = refs.filter { r in
            let t = r.title.lowercased()
            return t.contains("exploration") || t.contains("discovery")
        }
        guard !chosen.isEmpty else { return [] }

        var seen = Set<String>()
        var candidates: [Candidate] = []
        var position = 0
        for ref in chosen.prefix(2) {
            for track in await ListenBrainzClient.shared.playlistTracks(mbid: ref.mbid, token: token) {
                guard let artist = track.artist else { continue }
                let key = artist.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, !library.contains(key), !disliked.contains(key),
                      seen.insert(key).inserted else { continue }
                position += 1
                // High base score — this is LB's own curated on-taste discovery.
                candidates.append(Candidate(kind: .artist, artist: artist,
                                            similarity: max(0.4, 0.95 - Double(position) * 0.02),
                                            producer: id))
            }
        }
        return candidates
    }

    private func freshAlbums(username: String, token: String,
                             libraryAlbumKeys: Set<String>, disliked: Set<String>) async -> [Candidate] {
        let releases = await ListenBrainzClient.shared.freshReleases(username: username, token: token, days: freshReleaseDays)
        guard !releases.isEmpty else { return [] }

        // ISO dates sort lexicographically = chronologically, so a plain string
        // compare drops not-yet-released (thus un-acquirable) entries.
        let today: String = {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.timeZone = TimeZone(identifier: "UTC")
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: Date())
        }()

        var seen = Set<String>()
        var candidates: [Candidate] = []
        var position = 0
        for rel in releases {
            // Albums/EPs only — skip singles, broadcasts, DJ-mixes and unknown types.
            guard let type = rel.primaryType, type == "Album" || type == "EP" else { continue }
            if let date = rel.releaseDate, date > today { continue }   // still upcoming
            let artistKey = rel.artist.lowercased().trimmingCharacters(in: .whitespaces)
            guard !artistKey.isEmpty, !disliked.contains(artistKey) else { continue }
            let albumKey = "\(artistKey)|\(rel.album.lowercased().trimmingCharacters(in: .whitespaces))"
            guard !libraryAlbumKeys.contains(albumKey), seen.insert(albumKey).inserted else { continue }
            position += 1
            let year = rel.releaseDate.flatMap { Int($0.prefix(4)) }
            candidates.append(Candidate(kind: .album, artist: rel.artist, album: rel.album, year: year,
                                        similarity: max(0.5, 0.9 - Double(position) * 0.02),
                                        producer: id, artistMbid: rel.artistMbid,
                                        releaseGroupMbid: rel.releaseGroupMbid))
        }
        return candidates
    }
}
